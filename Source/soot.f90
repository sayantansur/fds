MODULE SOOT_ROUTINES

USE PRECISION_PARAMETERS
USE MESH_POINTERS
USE GLOBAL_CONSTANTS, ONLY: N_PARTICLE_BINS, MIN_PARTICLE_DIAMETER, MAX_PARTICLE_DIAMETER, K_BOLTZMANN, &
                            N_TRACKED_SPECIES, GRAV, AGGLOMERATION_INDEX
IMPLICIT NONE

PUBLIC CALC_AGGLOMERATION, INITIALIZE_AGGLOMERATION, SETTLING_VELOCITY,PARTICLE_RADIUS

REAL(EB) :: BIN_S,MIN_AGGLOMERATION=1.E-10_EB,LOGX,DLOGX
REAL(EB), ALLOCATABLE, DIMENSION(:) :: BIN_M, BIN_X,MOBILITY_FAC,A_FAC,PARTICLE_RADIUS
REAL(EB), ALLOCATABLE, DIMENSION(:,:) :: PHI_B_FAC,PHI_G_FAC,PHI_S_FAC,PHI_I_FAC,FU1_FAC,FU2_FAC,PARTICLE_MASS
REAL(EB), ALLOCATABLE, DIMENSION(:,:,:) :: BIN_ETA
INTEGER, ALLOCATABLE, DIMENSION(:,:,:) :: BIN_ETA_INDEX

CONTAINS

SUBROUTINE SETTLING_VELOCITY(NM)

! Routine related to gravitational sedimentation in gas phase.
! If gravitational deposition is enabled, transport depositing
! aerosol via WW minus settling velocity. K. Overholt
! WW_GRAV = g m_p B, assume CHI_D=1., B=mobility, m_p = particle mass

USE PHYSICAL_FUNCTIONS, ONLY: GET_VISCOSITY
USE GLOBAL_CONSTANTS, ONLY: PREDICTOR,GVEC,SOLID_BOUNDARY
REAL(EB) :: ZZ_GET(1:N_TRACKED_SPECIES),TMP_G,MU_G,KN,GRAV_FAC,KN_FAC,GRAV_VEL,RHS
INTEGER, INTENT(IN) :: NM
INTEGER :: I,J,K,N,IW,IIG,JJG,KKG,IOR
REAL(EB), POINTER, DIMENSION(:,:,:) :: U_GRAV=>NULL(),V_GRAV=>NULL(),W_GRAV=>NULL(),RHOP=>NULL()
REAL(EB), POINTER, DIMENSION(:,:,:,:) :: ZZP=>NULL()
TYPE(WALL_TYPE), POINTER :: WC=>NULL()

CALL POINT_TO_MESH(NM)

IF (PREDICTOR) THEN
   RHOP => RHO
   ZZP  => ZZ
ELSE
   RHOP => RHOS
   ZZP  => ZZS
ENDIF

U_GRAV => WORK7
V_GRAV => WORK8
W_GRAV => WORK9
U_GRAV = 0._EB
V_GRAV = 0._EB
W_GRAV = 0._EB

SPEC_LOOP: DO N=1,N_TRACKED_SPECIES
   IF (.NOT.SPECIES_MIXTURE(N)%DEPOSITING) CYCLE SPEC_LOOP

   GRAV_FAC = SPECIES_MIXTURE(N)%MEAN_DIAMETER**2*SPECIES_MIXTURE(N)%DENSITY_SOLID/18._EB
   KN_FAC = SQRT(2._EB*PI)/SPECIES_MIXTURE(N)%MEAN_DIAMETER
   DO K=1,KBAR
      DO J=1,JBAR
         DO I=1,IBAR
            IF (SOLID(CELL_INDEX(I,J,K))) CYCLE
            TMP_G = TMP(I,J,K)
            ZZ_GET(1:N_TRACKED_SPECIES) = ZZP(I,J,K,1:N_TRACKED_SPECIES)
            CALL GET_VISCOSITY(ZZ_GET,MU_G,TMP_G)
            KN = KN_FAC*MU_G/SQRT(PBAR(K,PRESSURE_ZONE(I,J,K))*RHOP(I,J,K))
            GRAV_VEL = GRAV_FAC*CUNNINGHAM(KN)/MU_G
            U_GRAV(I,J,K) = GVEC(1)*GRAV_VEL
            V_GRAV(I,J,K) = GVEC(2)*GRAV_VEL
            W_GRAV(I,J,K) = GVEC(3)*GRAV_VEL
         ENDDO
      ENDDO
   ENDDO

   ! Wall removal handled by wall BC

   WALL_LOOP: DO IW=1,N_EXTERNAL_WALL_CELLS+N_INTERNAL_WALL_CELLS
      WC=>WALL(IW)
      IF (WC%BOUNDARY_TYPE/=SOLID_BOUNDARY .OR. WC%ONE_D%UW < 0._EB) CYCLE WALL_LOOP
      IIG = WC%ONE_D%IIG
      JJG = WC%ONE_D%JJG
      KKG = WC%ONE_D%KKG
      IOR = WC%ONE_D%IOR
      SELECT CASE(IOR)
         CASE (-1)
            U_GRAV(IIG,JJG,KKG)   = 0._EB
         CASE ( 1)
            U_GRAV(IIG-1,JJG,KKG) = 0._EB
         CASE (-2)
            V_GRAV(IIG,JJG,KKG)   = 0._EB
         CASE ( 2)
            V_GRAV(IIG,JJG-1,KKG) = 0._EB
         CASE (-3)
            W_GRAV(IIG,JJG,KKG)   = 0._EB
         CASE ( 3)
            W_GRAV(IIG,JJG,KKG-1) = 0._EB
      END SELECT
   ENDDO WALL_LOOP

   DO K=1,KBAR
      DO J=1,JBAR
         DO I=1,IBAR
            IF (SOLID(CELL_INDEX(I,J,K))) CYCLE

            RHS = ( R(I)*FX(I,J,K,N)*U_GRAV(I,J,K) - R(I-1)*FX(I-1,J,K,N)*U_GRAV(I-1,J,K) )*RDX(I)*RRN(I) &
                + (      FY(I,J,K,N)*V_GRAV(I,J,K) -        FY(I,J-1,K,N)*V_GRAV(I,J-1,K) )*RDY(J)        &
                + (      FZ(I,J,K,N)*W_GRAV(I,J,K) -        FZ(I,J,K-1,N)*W_GRAV(I,J,K-1) )*RDZ(K)

            DEL_RHO_D_DEL_Z(I,J,K,N) = DEL_RHO_D_DEL_Z(I,J,K,N) - RHS
         ENDDO
      ENDDO
   ENDDO

ENDDO SPEC_LOOP

END SUBROUTINE SETTLING_VELOCITY


SUBROUTINE CALC_DEPOSITION(DT,NM)

USE PHYSICAL_FUNCTIONS, ONLY: GET_VISCOSITY,GET_CONDUCTIVITY
USE GLOBAL_CONSTANTS, ONLY: EVACUATION_ONLY,SOLID_PHASE_ONLY,SOLID_BOUNDARY,N_TRACKED_SPECIES,K_BOLTZMANN,LES,&
                            GRAVITATIONAL_DEPOSITION,TURBULENT_DEPOSITION,THERMOPHORETIC_DEPOSITION,GVEC,PREDICTOR
USE TURBULENCE, ONLY: WALL_MODEL
INTEGER, INTENT(IN) :: NM
REAL(EB), INTENT(IN) :: DT
REAL(EB), PARAMETER :: CS=1.17_EB,CT=2.2_EB,CM=1.146_EB,A1=1.257_EB,A2=0.4_EB,A32=1.1_EB
REAL(EB), PARAMETER :: CM3=3._EB*CM,CS2=CS*2._EB,CT2=2._EB*CT
REAL(EB) :: U_THERM,U_TURB,TGAS,TWALL,MUGAS,Y_AEROSOL,RHOG,ZZ_GET(1:N_TRACKED_SPECIES),YDEP,K_AIR,TMP_FILM,KN,ALPHA,DTMPDX,&
            KN_EXP,TAU_PLUS,DN,TAU_PLUS_C,VEL_W,U2,V2,W2,U_GRAV,D_SOLID,MW_RATIO
INTEGER  :: IIG,JJG,KKG,IW,IOR,N
TYPE(SPECIES_MIXTURE_TYPE), POINTER :: SM=>NULL()
TYPE(SPECIES_TYPE), POINTER :: SS=>NULL()
TYPE(WALL_TYPE), POINTER :: WC=>NULL()

IF (PREDICTOR) RETURN
IF (EVACUATION_ONLY(NM)) RETURN
IF (SOLID_PHASE_ONLY) RETURN

CALL POINT_TO_MESH(NM)

SMIX_LOOP: DO N=1,N_TRACKED_SPECIES
   SM=>SPECIES_MIXTURE(N)
   IF (.NOT.SM%DEPOSITING) CYCLE SMIX_LOOP
   SS=>SPECIES(SPECIES_MIXTURE(N)%SINGLE_SPEC_INDEX)
   U_THERM = 0._EB
   U_TURB = 0._EB
   U_GRAV = 0._EB
   IF (TURBULENT_DEPOSITION) TAU_PLUS_C = SM%DENSITY_SOLID*SM%MEAN_DIAMETER**2/18._EB
   WALL_CELL_LOOP: DO IW=1,N_EXTERNAL_WALL_CELLS+N_INTERNAL_WALL_CELLS
      WC=>WALL(IW)
      IF (WC%BOUNDARY_TYPE/=SOLID_BOUNDARY .OR. WC%ONE_D%UW < 0._EB) CYCLE WALL_CELL_LOOP
      IOR = WC%ONE_D%IOR
      IIG = WC%ONE_D%IIG
      JJG = WC%ONE_D%JJG
      KKG = WC%ONE_D%KKG
      ZZ_GET(1:N_TRACKED_SPECIES) = MAX(0._EB,ZZ(IIG,JJG,KKG,1:N_TRACKED_SPECIES))
      IF (ZZ_GET(N) < 1.E-14_EB) CYCLE WALL_CELL_LOOP
      MW_RATIO = SPECIES_MIXTURE(N)%RCON/RSUM(IIG,JJG,KKG)
      TWALL = WC%ONE_D%TMP_F
      TGAS = TMP(IIG,JJG,KKG)
      TMP_FILM = 0.5_EB*(TGAS+TWALL)
      CALL GET_VISCOSITY(ZZ_GET,MUGAS,TMP_FILM)
      CALL GET_CONDUCTIVITY(ZZ_GET,K_AIR,TMP_FILM)
      DN = 1/WC%ONE_D%RDN
      KN = MUGAS/SM%MEAN_DIAMETER*SQRT(2._EB*PI/(PBAR(KKG,PRESSURE_ZONE(IIG,JJG,KKG))*RHO(IIG,JJG,KKG)))
      KN_EXP = KN*(A1+A2*EXP(-A32/KN))
      RHOG = RHO(IIG,JJG,KKG)
      ALPHA = K_AIR/SM%CONDUCTIVITY_SOLID
      IF (LES) THEN
         DTMPDX = WC%ONE_D%HEAT_TRANS_COEF*(TGAS-TWALL)/K_AIR
      ELSE
         DTMPDX = (TGAS-TWALL)*WC%ONE_D%RDN
      ENDIF
      IF (THERMOPHORETIC_DEPOSITION) U_THERM = CS2*(ALPHA+CT*KN)*(1._EB+KN_EXP)/((1._EB+CM3*KN)*(1+2*ALPHA+CT2*KN)) * &
                                               MUGAS/(TGAS*RHOG)*DTMPDX
      IF (GRAVITATIONAL_DEPOSITION) THEN
         U_GRAV = -GVEC(ABS(IOR))*SIGN(1,IOR)*CUNNINGHAM(KN)*SM%MEAN_DIAMETER**2*SM%DENSITY_SOLID/(18._EB*MUGAS)
         ! Prevent negative settling velocity at downward facing surfaces
         U_GRAV = MAX(0._EB,U_GRAV)
      ENDIF
      IF (TURBULENT_DEPOSITION) THEN
         U2 = 0.25_EB*(US(IIG,JJG,KKG)+US(IIG-1,JJG,KKG))**2
         V2 = 0.25_EB*(VS(IIG,JJG,KKG)+VS(IIG,JJG-1,KKG))**2
         W2 = 0.25_EB*(WS(IIG,JJG,KKG)+WS(IIG,JJG,KKG-1))**2
         SELECT CASE(ABS(IOR))
            CASE(1)
               U2 = 0._EB
            CASE(2)
               V2 = 0._EB
            CASE(3)
               W2 = 0._EB
         END SELECT
         VEL_W = SQRT(U2+V2+W2)
         TAU_PLUS = TAU_PLUS_C/MUGAS**2*WC%U_TAU**2*RHOG
         IF (TAU_PLUS < 0.2_EB) THEN ! Diffusion regime
            D_SOLID = K_BOLTZMANN*TGAS*CUNNINGHAM(KN)/(3._EB*PI*MUGAS*SM%MEAN_DIAMETER)
            U_TURB = WC%U_TAU * 0.086_EB*(MUGAS/RHOG/D_SOLID)**(-0.7_EB)
         ELSEIF (TAU_PLUS >= 0.2_EB .AND. TAU_PLUS < 22.9_EB) THEN ! Diffusion-impaction regime
            U_TURB = WC%U_TAU * 3.5E-4_EB * TAU_PLUS**2
         ELSE ! Inertia regime
            U_TURB = WC%U_TAU * 0.17_EB
         ENDIF
      ENDIF
      WC%V_DEP = MAX(0._EB,U_THERM+U_TURB+U_GRAV)
      IF (WC%V_DEP <= TWO_EPSILON_EB) CYCLE WALL_CELL_LOOP
      ZZ_GET = ZZ_GET * RHOG
      Y_AEROSOL = ZZ_GET(N)
      YDEP = Y_AEROSOL*MIN(1._EB,(WC%V_DEP)*DT*WC%ONE_D%RDN)
      ZZ_GET(N) = Y_AEROSOL - YDEP
      IF (SM%AWM_INDEX > 0) WC%AWM_AEROSOL(SM%AWM_INDEX)=WC%AWM_AEROSOL(SM%AWM_INDEX)+YDEP/WC%ONE_D%RDN
      IF (SS%AWM_INDEX > 0) WC%AWM_AEROSOL(SS%AWM_INDEX)=WC%AWM_AEROSOL(SS%AWM_INDEX)+YDEP/WC%ONE_D%RDN
      
      D_SOURCE(IIG,JJG,KKG) = D_SOURCE(IIG,JJG,KKG) - MW_RATIO*YDEP / RHOG / DT
      M_DOT_PPP(IIG,JJG,KKG,N) = M_DOT_PPP(IIG,JJG,KKG,N) - YDEP / DT
      
      !RHO(IIG,JJG,KKG) = RHOG - YDEP
      !ZZ(IIG,JJG,KKG,1:N_TRACKED_SPECIES) = ZZ_GET(1:N_TRACKED_SPECIES) / RHO(IIG,JJG,KKG)
   ENDDO WALL_CELL_LOOP

ENDDO SMIX_LOOP

END SUBROUTINE CALC_DEPOSITION


SUBROUTINE INITIALIZE_AGGLOMERATION
INTEGER :: I,II,III
REAL(EB) :: E_PK,MIN_PARTICLE_MASS,MAX_PARTICLE_MASS

MIN_PARTICLE_MASS = 0.125_EB*FOTHPI * SPECIES(AGGLOMERATION_INDEX)%DENSITY_SOLID*MIN_PARTICLE_DIAMETER**3
MAX_PARTICLE_MASS = 0.125_EB*FOTHPI * SPECIES(AGGLOMERATION_INDEX)%DENSITY_SOLID*MAX_PARTICLE_DIAMETER**3
BIN_S = (MAX_PARTICLE_MASS/MIN_PARTICLE_MASS)**(1._EB/REAL(N_PARTICLE_BINS,EB))

ALLOCATE(BIN_M(0:N_PARTICLE_BINS))
ALLOCATE(BIN_X(1:N_PARTICLE_BINS))
BIN_M(0)= MIN_PARTICLE_MASS
DO I=1,N_PARTICLE_BINS
   BIN_M(I) = BIN_M(I-1)*BIN_S
   BIN_X(I) = 2._EB*BIN_M(I)/(1._EB+BIN_S)
ENDDO

LOGX = LOG10(BIN_X(1))
DLOGX = REAL(N_PARTICLE_BINS,EB)/(LOG10(BIN_X(N_PARTICLE_BINS))-LOGX)

ALLOCATE(BIN_ETA(N_PARTICLE_BINS,N_PARTICLE_BINS,2))
BIN_ETA = 0._EB
ALLOCATE(BIN_ETA_INDEX(N_PARTICLE_BINS,N_PARTICLE_BINS,2))
BIN_ETA_INDEX = -1

ALLOCATE(PHI_B_FAC(N_PARTICLE_BINS,N_PARTICLE_BINS))
ALLOCATE(PARTICLE_MASS(N_PARTICLE_BINS,N_PARTICLE_BINS))
ALLOCATE(PHI_G_FAC(N_PARTICLE_BINS,N_PARTICLE_BINS))
ALLOCATE(PHI_S_FAC(N_PARTICLE_BINS,N_PARTICLE_BINS))
ALLOCATE(PHI_I_FAC(N_PARTICLE_BINS,N_PARTICLE_BINS))
ALLOCATE(FU1_FAC(N_PARTICLE_BINS,N_PARTICLE_BINS))
ALLOCATE(FU2_FAC(N_PARTICLE_BINS,N_PARTICLE_BINS))
ALLOCATE(MOBILITY_FAC(N_PARTICLE_BINS))
ALLOCATE(A_FAC(N_PARTICLE_BINS))
ALLOCATE(PARTICLE_RADIUS(1:N_PARTICLE_BINS))

DO I=1,N_PARTICLE_BINS
   PARTICLE_RADIUS(I) = (BIN_X(I) / FOTHPI / SPECIES(AGGLOMERATION_INDEX)%DENSITY_SOLID)**ONTH
   MOBILITY_FAC(I) = 1._EB/(6._EB*PI*PARTICLE_RADIUS(I))
   A_FAC(I) = SQRT(2._EB*K_BOLTZMANN*BIN_X(I)/PI)
END DO
DO I=1,N_PARTICLE_BINS
   DO II=1,N_PARTICLE_BINS
      PARTICLE_MASS(I,II) = BIN_X(I) + BIN_X(II)
      E_PK = MIN(PARTICLE_RADIUS(I),PARTICLE_RADIUS(II))**2/(2._EB*(PARTICLE_RADIUS(I)+PARTICLE_RADIUS(II))**2)
      PHI_G_FAC(I,II) = E_PK*(PARTICLE_RADIUS(I)+PARTICLE_RADIUS(II))**2*GRAV
      PHI_B_FAC(I,II)= 4._EB*PI*K_BOLTZMANN*(PARTICLE_RADIUS(I)+PARTICLE_RADIUS(II))
      !Check what Re and r are for PHI_I and _S
      PHI_S_FAC(I,II) = E_PK*(PARTICLE_RADIUS(I)+PARTICLE_RADIUS(II))**3*SQRT(8._EB*PI/15._EB)
      PHI_I_FAC(I,II) = E_PK*(PARTICLE_RADIUS(I)+PARTICLE_RADIUS(II))**2*(512._EB*PI**3/15._EB)**0.25_EB
      !Check Fu1 formula*******
      FU1_FAC(I,II) = (PARTICLE_RADIUS(I)+PARTICLE_RADIUS(II))/K_BOLTZMANN*&
                      SQRT(8._EB*K_BOLTZMANN/PI*(1._EB/BIN_X(I)+1._EB/BIN_X(II)))
      FU2_FAC(I,II) = 2._EB/(PARTICLE_RADIUS(I)+PARTICLE_RADIUS(II))
      BINDO:DO III=2,N_PARTICLE_BINS
         IF (PARTICLE_MASS(I,II)>BIN_X(N_PARTICLE_BINS)) THEN
            BIN_ETA_INDEX(I,II,:) = N_PARTICLE_BINS
            BIN_ETA(I,II,:) = 0.5_EB*BIN_X(N_PARTICLE_BINS)/PARTICLE_MASS(I,II)
            EXIT BINDO
         ELSE
            IF (PARTICLE_MASS(I,II) > BIN_X(III-1) .AND. PARTICLE_MASS(I,II) < BIN_X(III)) THEN
               BIN_ETA_INDEX(I,II,1) = III-1
               BIN_ETA(I,II,1) = (BIN_X(III)-PARTICLE_MASS(I,II))/(BIN_X(III)-BIN_X(III-1))
               BIN_ETA_INDEX(I,II,2) = III
               BIN_ETA(I,II,2) = (PARTICLE_MASS(I,II)-BIN_X(III-1))/(BIN_X(III)-BIN_X(III-1))
               IF (I==II) BIN_ETA(I,II,:) = BIN_ETA(I,II,:) *0.5_EB
               EXIT BINDO
            ENDIF
         ENDIF
      ENDDO BINDO
   ENDDO
ENDDO

BIN_ETA(N_PARTICLE_BINS,N_PARTICLE_BINS,1) = 1._EB
BIN_ETA_INDEX(N_PARTICLE_BINS,N_PARTICLE_BINS,1) = N_PARTICLE_BINS
BIN_ETA(N_PARTICLE_BINS,N_PARTICLE_BINS,2) = 0._EB
BIN_ETA_INDEX(N_PARTICLE_BINS,N_PARTICLE_BINS,2) = N_PARTICLE_BINS



END SUBROUTINE INITIALIZE_AGGLOMERATION

SUBROUTINE CALC_AGGLOMERATION(DT,NM)
USE PHYSICAL_FUNCTIONS,ONLY:GET_VISCOSITY
INTEGER :: I,J,K,N,NN,IM1,IM2,JM1,JM2,KM1,KM2,IP1,JP1,KP1
INTEGER, INTENT(IN) :: NM
REAL(EB), INTENT(IN) :: DT
REAL(EB) :: DUDX,DVDY,DWDZ,ONTHDIV,S11,S22,S33,DUDY,DUDZ,DVDX,DVDZ,DWDX,DWDY,S12,S23,S13,STRAIN_RATE
REAL(EB) :: KN,MFP,N_I(N_PARTICLE_BINS),N0(N_PARTICLE_BINS),N1(N_PARTICLE_BINS),N2(N_PARTICLE_BINS),N3(N_PARTICLE_BINS),&
            RHOG,TMPG,MUG,TERMINAL(N_PARTICLE_BINS),&
            FU,MOBILITY(N_PARTICLE_BINS),ZZ_GET(1:N_TRACKED_SPECIES),AM,AMT(N_PARTICLE_BINS),&
            PHI_B,PHI_S,PHI_G,PHI_I,PHI(N_PARTICLE_BINS,N_PARTICLE_BINS),VREL,FU1,FU2,DT_SUBSTEP,DT_SUM,TOL
REAL(EB), PARAMETER :: AMFAC=2._EB*K_BOLTZMANN/PI
CALL POINT_TO_MESH(NM)
ZZ_GET = 0._EB

GEOMETRY_LOOP:DO K=1,KBAR
   DO J=1,JBAR
      DO I=1,IBAR
         IF (SOLID(CELL_INDEX(I,J,K))) CYCLE
         N0(1:N_PARTICLE_BINS)=ZZ(I,J,K,AGGLOMERATION_INDEX:AGGLOMERATION_INDEX+N_PARTICLE_BINS-1)
         IF (ALL(N0 < MIN_AGGLOMERATION)) CYCLE
         RHOG = RHO(I,J,K)
         N0 = N0*RHOG/BIN_X
         ZZ_GET(1:N_TRACKED_SPECIES) = ZZ(I,J,K,1:N_TRACKED_SPECIES)
         TMPG = TMP(I,J,K)
         CALL GET_VISCOSITY(ZZ_GET,MUG,TMPG)
         MFP = MUG*SQRT(PI/(2._EB*PBAR(K,PRESSURE_ZONE(I,J,K))*RHOG))
         IM1 = MAX(0,I-1)
         JM1 = MAX(0,J-1)
         KM1 = MAX(0,K-1)
         IM2 = MAX(1,I-1)
         JM2 = MAX(1,J-1)
         KM2 = MAX(1,K-1)
         IP1 = MIN(IBAR,I+1)
         JP1 = MIN(JBAR,J+1)
         KP1 = MIN(KBAR,K+1)
         DUDX = RDX(I)*(U(I,J,K)-U(IM1,J,K))
         DVDY = RDY(J)*(V(I,J,K)-V(I,JM1,K))
         DWDZ = RDZ(K)*(W(I,J,K)-W(I,J,KM1))
         ONTHDIV = ONTH*(DUDX+DVDY+DWDZ)
         S11 = DUDX - ONTHDIV
         S22 = DVDY - ONTHDIV
         S33 = DWDZ - ONTHDIV
         DUDY = 0.25_EB*RDY(J)*(U(I,JP1,K)-U(I,JM2,K)+U(IM1,JP1,K)-U(IM1,JM2,K))
         DUDZ = 0.25_EB*RDZ(K)*(U(I,J,KP1)-U(I,J,KM2)+U(IM1,J,KP1)-U(IM1,J,KM2))
         DVDX = 0.25_EB*RDX(I)*(V(IP1,J,K)-V(IM2,J,K)+V(IP1,JM1,K)-V(IM2,JM1,K))
         DVDZ = 0.25_EB*RDZ(K)*(V(I,J,KP1)-V(I,J,KM2)+V(I,JM1,KP1)-V(I,JM1,KM2))
         DWDX = 0.25_EB*RDX(I)*(W(IP1,J,K)-W(IM2,J,K)+W(IP1,J,KM1)-W(IM2,J,KM1))
         DWDY = 0.25_EB*RDY(J)*(W(I,JP1,K)-W(I,JM2,K)+W(I,JP1,KM1)-W(I,JM2,KM1))
         S12 = 0.5_EB*(DUDY+DVDX)
         S13 = 0.5_EB*(DUDZ+DWDX)
         S23 = 0.5_EB*(DVDZ+DWDY)
         STRAIN_RATE = 2._EB*(S11**2 + S22**2 + S33**2 + 2._EB*(S12**2 + S13**2 + S23**2))

         N_I = N0

         DO N=1,N_PARTICLE_BINS
            KN=MFP/PARTICLE_RADIUS(N)
            !Verify CN
            MOBILITY(N) = CUNNINGHAM(KN)*MOBILITY_FAC(N)/MUG
            TERMINAL(N) = MOBILITY(N)*GRAV*BIN_X(N)
            AM = A_FAC(N)*SQRT(TMPG)*MOBILITY(N)
            AMT(N) = ((PARTICLE_RADIUS(N)+AM)**3-(PARTICLE_RADIUS(N)**2+AM**2)**1.5_EB)/&
                     (3._EB*PARTICLE_RADIUS(N)*AM)-PARTICLE_RADIUS(N)
         ENDDO
         DO N=1,N_PARTICLE_BINS
            DO NN=1,N_PARTICLE_BINS
               IF (NN<N) CYCLE
               FU1 = FU1_FAC(N,NN)/(SQRT(TMPG)*(MOBILITY(N)+MOBILITY(NN)))
               FU2 = 1._EB+FU2_FAC(N,NN)*SQRT(AMT(NN)**2+AMT(N)**2)
               FU = 1._EB/FU1+1._EB/FU2
               FU = 1._EB/FU
               PHI_B = PHI_B_FAC(N,NN)*(MOBILITY(N)+MOBILITY(NN))*FU*TMPG
               VREL = ABS(TERMINAL(N)-TERMINAL(NN))
               PHI_G = PHI_G_FAC(N,NN)*VREL
               PHI_S = PHI_S_FAC(N,NN)*STRAIN_RATE
               PHI_I = PHI_I_FAC(N,NN)*((RHOG/MUG)**2*STRAIN_RATE**3)**0.25_EB*VREL/GRAV
               PHI(N,NN) = PHI_B+PHI_G+SQRT(PHI_S**2+PHI_I**2)
               PHI(NN,N) = PHI(N,NN)
            ENDDO
         ENDDO
         DT_SUBSTEP=DT
         DT_SUM = 0._EB
         STEPLOOP: DO WHILE (DT_SUM <DT)
            N1 = 0._EB
            N2 = 0._EB
            N3 = 0._EB
            AGGLOMERATE_LOOP:DO N=1,N_PARTICLE_BINS
               DO NN=N,N_PARTICLE_BINS
                  IF (N0(N)<MIN_AGGLOMERATION .OR. N0(NN)<MIN_AGGLOMERATION) CYCLE
                  !Remove particles that agglomerate
                  N1(N)=N1(N)-PHI(NN,N)*N0(N)*N0(NN)*DT_SUBSTEP
                  IF (NN/=N) N1(NN)=N1(NN)-PHI(NN,N)*N0(N)*N0(NN)*DT_SUBSTEP
                  ! Create new particles from agglomeration
                  N2(BIN_ETA_INDEX(N,NN,1)) = N2(BIN_ETA_INDEX(N,NN,1)) + BIN_ETA(N,NN,1)*PHI(N,NN)*N0(N)*N0(NN)*DT_SUBSTEP
                  N2(BIN_ETA_INDEX(N,NN,2)) = N2(BIN_ETA_INDEX(N,NN,2)) + BIN_ETA(N,NN,2)*PHI(N,NN)*N0(N)*N0(NN)*DT_SUBSTEP
               ENDDO
            ENDDO AGGLOMERATE_LOOP
            N3 = N1 + N2
            N3 = N3 + N0
            TOL = MAXVAL((N0-N3)/N0)
            IF (TOL > 0.3_EB) THEN
               DT_SUBSTEP = DT_SUBSTEP * 0.3_EB/ TOL
            ELSE
               DT_SUM = DT_SUM + DT_SUBSTEP
               DT_SUBSTEP = MIN(DT-DT_SUM,1.5_EB*DT_SUBSTEP)
               N0 = N3
            ENDIF
         END DO STEPLOOP
         N3 = N3*SUM(N_I*BIN_X)/SUM(N3*BIN_X)
         ZZ(I,J,K,AGGLOMERATION_INDEX:AGGLOMERATION_INDEX+N_PARTICLE_BINS-1) = N3 * BIN_X / RHOG
      ENDDO
   ENDDO
ENDDO GEOMETRY_LOOP

END SUBROUTINE CALC_AGGLOMERATION


SUBROUTINE SURFACE_OXIDATION(DT,NM)
USE GLOBAL_CONSTANTS, ONLY : R0,SOLID_BOUNDARY,MW_O2,O2_INDEX,MW_CO2,CO2_INDEX
USE PHYSICAL_FUNCTIONS, ONLY: GET_MOLECULAR_WEIGHT, GET_MASS_FRACTION
INTEGER,INTENT(IN) :: NM
REAL(EB), INTENT(IN) :: DT
REAL(EB) :: M_SOOT,MW,Y_O2,TSOOT,RHOG,A=-211000._EB*1000._EB/R0,DMDT,DM,DAIR_FAC,ZZ_AIR,ZZ_GET(1:N_TRACKED_SPECIES),VOL,Q_FAC,DM_FAC
INTEGER :: IW,NS,IIG,JJG,KKG,AGG_INDEX
TYPE(SPECIES_TYPE),POINTER :: SS=>NULL()
TYPE(SPECIES_MIXTURE_TYPE), POINTER :: SM=>NULL()
TYPE(WALL_TYPE), POINTER :: WC=>NULL()

CALL POINT_TO_MESH(NM)
AGG_INDEX = SPECIES_MIXTURE(AGGLOMERATION_INDEX)%SINGLE_SPEC_INDEX
SS=> SPECIES(AGG_INDEX)

ZZ_GET = 0._EB
CALL GET_MASS_FRACTION(ZZ_GET,O2_INDEX,Y_O2)
DAIR_FAC = MW_O2/(Y_O2*SS%MW)
Q_FAC = -SPECIES(CO2_INDEX)%H_F/SS%MW*MW_CO2
DM_FAC = 4.7E12_EB/MW_O2
WALL_CELL_LOOP: DO IW = 1,N_EXTERNAL_WALL_CELLS+N_INTERNAL_WALL_CELLS
      WC=>WALL(IW)
      IF (WC%BOUNDARY_TYPE/=SOLID_BOUNDARY) CYCLE WALL_CELL_LOOP
      IF (WC%AWM_AEROSOL(SS%AWM_INDEX)<1.E-12) CYCLE WALL_CELL_LOOP
      M_SOOT = WC%AWM_AEROSOL(SS%AWM_INDEX)*WC%AW
      IIG = WC%ONE_D%IIG
      JJG = WC%ONE_D%JJG
      KKG = WC%ONE_D%KKG
      ZZ_GET = 0._EB
      ZZ_GET(1:N_TRACKED_SPECIES) = ZZ(IIG,JJG,KKG,1:N_TRACKED_SPECIES)
      ZZ_AIR = 1._EB -  MAX(0._EB,SUM(ZZ_GET))
      IF (ZZ_AIR < 1.E-10_EB) CYCLE WALL_CELL_LOOP
      CALL GET_MASS_FRACTION(ZZ_GET,O2_INDEX,Y_O2)
      CALL GET_MOLECULAR_WEIGHT(ZZ_GET,MW)
      TSOOT = 0.5_EB*(TMP(IIG,JJG,KKG)+WC%ONE_D%TMP_F)
      RHOG = RHO(IIG,JJG,KKG)
      VOL = DX(IIG)*RC(IIG)*DY(JJG)*DZ(KKG)
      DMDT = M_SOOT*Y_O2*MW/RHOG*DM_FAC*EXP(A/TSOOT)
      DM = MIN(M_SOOT,DMDT*DT,Y_O2*RHOG*VOL/MW_O2*SS%MW)
      ZZ(IIG,JJG,KKG,7) = ZZ(IIG,JJG,KKG,7) + DM*DAIR_FAC/(RHOG*VOL)
      Q(IIG,JJG,KKG) = Q(IIG,JJG,KKG) + DM*Q_FAC/VOL
      DM = DM/WC%AW

      DO NS=1,N_TRACKED_SPECIES
         SM=>SPECIES_MIXTURE(NS)
         IF (SM%SINGLE_SPEC_INDEX==AGG_INDEX) THEN
            IF (SM%AWM_INDEX > 0) WC%AWM_AEROSOL(SM%AWM_INDEX) = WC%AWM_AEROSOL(SM%AWM_INDEX) - &
                                     DM/WC%AWM_AEROSOL(SS%AWM_INDEX)*WC%AWM_AEROSOL(SM%AWM_INDEX)
         ENDIF
      ENDDO

      WC%AWM_AEROSOL(SS%AWM_INDEX) = WC%AWM_AEROSOL(SS%AWM_INDEX) - DM

ENDDO WALL_CELL_LOOP

END SUBROUTINE SURFACE_OXIDATION

REAL(EB) FUNCTION CUNNINGHAM(KN)
REAL(EB), INTENT(IN) :: KN
REAL(EB), PARAMETER :: K1=1.25_EB,K2=0.41_EB,K3=0.88_EB

CUNNINGHAM = 1._EB+K1*KN+K2*KN*EXP(-K3/KN)

END FUNCTION CUNNINGHAM

END MODULE SOOT_ROUTINES
