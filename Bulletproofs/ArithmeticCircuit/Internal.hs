{-# LANGUAGE ViewPatterns, RecordWildCards, ScopedTypeVariables #-}
{-# LANGUAGE DeriveAnyClass, DeriveGeneric #-}

module Bulletproofs.ArithmeticCircuit.Internal where

import Protolude hiding (head)
import Data.List (head)
import qualified Data.List as List
import qualified Data.Map as Map
import Test.QuickCheck
import PrimeField (PrimeField(..), toInt)

import System.Random.Shuffle (shuffleM)
import qualified Crypto.Random.Types as Crypto (MonadRandom(..))
import Crypto.Number.Generate (generateMax, generateBetween)
import Control.Monad.Random (MonadRandom)
import qualified Crypto.PubKey.ECC.Types as Crypto
import qualified Crypto.PubKey.ECC.Prim as Crypto

import Bulletproofs.Curve
import Bulletproofs.Utils
import Bulletproofs.RangeProof
import qualified Bulletproofs.InnerProductProof as IPP

data ArithCircuitProofError
  = TooManyGates Integer  -- ^ The number of gates is too high
  | NNotPowerOf2 Integer  -- ^ The number of gates is not a power of 2
  deriving (Show, Eq)

data ArithCircuitProof f
  = ArithCircuitProof
    { tBlinding :: f
    -- ^ Blinding factor of the T1 and T2 commitments,
    -- combined into the form required to make the committed version of the x-polynomial add up
    , mu :: f
    -- ^ Blinding factor required for the Verifier to verify commitments A, S
    , t :: f
    -- ^ Dot product of vectors l and r that prove knowledge of the value in range
    -- t = t(x) = l(x) · r(x)
    , aiCommit :: Crypto.Point
    -- ^ Commitment to vectors aL and aR
    , aoCommit :: Crypto.Point
    -- ^ Commitment to vectors aO
    , sCommit :: Crypto.Point
    -- ^ Commitment to new vectors sL, sR, created at random by the Prover
    , tCommits :: [Crypto.Point]
    -- ^ Commitments to t1, t3, t4, t5, t6
    , productProof :: IPP.InnerProductProof f
    } deriving (Show, Eq, Generic, NFData)

data ArithCircuit f
  = ArithCircuit
    { weights :: GateWeights f
      -- ^ Weights for vectors of left and right inputs and for vector of outputs
    , commitmentWeights :: [[f]]
      -- ^ Weigths for a commitments V of rank m
    , cs :: [f]
      -- ^ Vector of constants of size Q
    } deriving (Show, Eq, Generic, NFData)


data GateWeights f
  = GateWeights
    { wL :: [[f]] -- ^ WL ∈ F^(Q x n)
    , wR :: [[f]] -- ^ WR ∈ F^(Q x n)
    , wO :: [[f]] -- ^ WO ∈ F^(Q x n)
    } deriving (Show, Eq, Generic, NFData)

data ArithWitness f
  = ArithWitness
  { assignment :: Assignment f -- ^ Vectors of left and right inputs and vector of outputs
  , commitments :: [Crypto.Point] -- ^ Vector of commited input values ∈ F^m
  , commitBlinders :: [f] -- ^ Vector of blinding factors for input values ∈ F^m
  } deriving (Show, Eq, Generic, NFData)

data Assignment f
  = Assignment
    { aL :: [f] -- ^ aL ∈ F^n. Vector of left inputs of each multiplication gate
    , aR :: [f] -- ^ aR ∈ F^n. Vector of right inputs of each multiplication gate
    , aO :: [f] -- ^ aO ∈ F^n. Vector of outputs of each multiplication gate
    } deriving (Show, Eq, Generic, NFData)

-- | Pad circuit weights to make n be a power of 2, which
-- is required to compute the inner product proof
padCircuit :: Num f => ArithCircuit f -> ArithCircuit f
padCircuit ArithCircuit{..}
  = ArithCircuit
    { weights = GateWeights wLNew wRNew wONew
    , commitmentWeights = commitmentWeights
    , cs = cs
    }
  where
    GateWeights{..} = weights
    wLNew = padToNearestPowerOfTwo <$> wL
    wRNew = padToNearestPowerOfTwo <$> wR
    wONew = padToNearestPowerOfTwo <$> wO

-- | Pad assignment vectors to make their length n be a power of 2, which
-- is required to compute the inner product proof
padAssignment :: Num f => Assignment f -> Assignment f
padAssignment Assignment{..}
  = Assignment aLNew aRNew aONew
  where
    aLNew = padToNearestPowerOfTwo aL
    aRNew = padToNearestPowerOfTwo aR
    aONew = padToNearestPowerOfTwo aO

delta :: (KnownNat p) => Integer -> PrimeField p -> [PrimeField p] -> [PrimeField p] -> PrimeField p
delta n y zwL zwR= (powerVector (recip y) n `hadamardp` zwR) `dot` zwL

commitBitVector :: (KnownNat p) => PrimeField p -> [PrimeField p] -> [PrimeField p] -> Crypto.Point
commitBitVector vBlinding vL vR = vLG `addP` vRH `addP` vBlindingH
  where
    vBlindingH = vBlinding `mulP` h
    vLG = sumExps vL gs
    vRH = sumExps vR hs

shamirGxGxG :: (Show f, Num f) => Crypto.Point -> Crypto.Point -> Crypto.Point -> f
shamirGxGxG p1 p2 p3
  = fromInteger $ oracle $ show _q <> pointToBS p1 <> pointToBS p2 <> pointToBS p3

shamirGs :: (Show f, Num f) => [Crypto.Point] -> f
shamirGs ps = fromInteger $ oracle $ show _q <> foldMap pointToBS ps

shamirZ :: (Show f, Num f) => f -> f
shamirZ z = fromInteger $ oracle $ show _q <> show z

---------------------------------------------
-- Polynomials
---------------------------------------------

evaluatePolynomial :: (Num f) => Integer -> [[f]] -> f -> [f]
evaluatePolynomial (fromIntegral -> n) poly x
  = foldl'
    (\acc (idx, e) -> acc ^+^ ((*) (x ^ idx) <$> e))
    (replicate n 0)
    (zip [0..] poly)

multiplyPoly :: Num n => [[n]] -> [[n]] -> [n]
multiplyPoly l r
  = snd <$> Map.toList (foldl' (\accL (i, li)
      -> foldl'
          (\accR (j, rj) -> case Map.lookup (i + j) accR of
              Just x -> Map.insert (i + j) (x + (li `dot` rj)) accR
              Nothing -> Map.insert (i + j) (li `dot` rj) accR
          ) accL (zip [0..] r))
      (Map.empty :: Num n => Map.Map Int n)
      (zip [0..] l))


---------------------------------------------
-- Linear algebra
---------------------------------------------

vectorMatrixProduct :: (Num f) => [f] -> [[f]] -> [f]
vectorMatrixProduct v m
  = sum . zipWith (*) v <$> transpose m

vectorMatrixProductT :: (Num f) => [f] -> [[f]] -> [f]
vectorMatrixProductT v m
  = sum . zipWith (*) v <$> m

matrixVectorProduct :: (Num f) => [[f]] -> [f] -> [f]
matrixVectorProduct m v
  = head $ matrixProduct m [v]

powerMatrix :: (Num f) => [[f]] -> Integer -> [[f]]
powerMatrix m 0 = m
powerMatrix m n = matrixProduct m (powerMatrix m (n-1))

matrixProduct :: Num a => [[a]] -> [[a]] -> [[a]]
matrixProduct a b = (\ar -> sum . zipWith (*) ar <$> transpose b) <$> a

insertAt :: Int -> a -> [a] -> [a]
insertAt z y xs = as ++ (y : bs)
  where
    (as, bs) = splitAt z xs

genIdenMatrix :: (Num f) => Integer -> [[f]]
genIdenMatrix size = (\x -> (\y -> fromIntegral (fromEnum (x == y))) <$> [1..size]) <$> [1..size]

genZeroMatrix :: (Num f) => Integer -> Integer -> [[f]]
genZeroMatrix (fromIntegral -> n) (fromIntegral -> m) = replicate n (replicate m 0)

computeInputValues :: (KnownNat p) => GateWeights (PrimeField p) -> [[PrimeField p]] -> Assignment (PrimeField p) -> [PrimeField p] -> [PrimeField p]
computeInputValues GateWeights{..} wV Assignment{..} cs
  = solveLinearSystem $ zipWith (\row s -> reverse $ s : row) wV solutions
  where
    solutions = vectorMatrixProductT aL wL
        ^+^ vectorMatrixProductT aR wR
        ^+^ vectorMatrixProductT aO wO
        ^-^ cs

gaussianReduce :: (KnownNat p) => [[PrimeField p]] -> [[PrimeField p]]
gaussianReduce matrix = fixlastrow $ foldl reduceRow matrix [0..length matrix-1]
  where
    -- Swaps element at position a with element at position b.
    swap xs a b
     | a > b = swap xs b a
     | a == b = xs
     | a < b = let (p1, p2) = splitAt a xs
                   (p3, p4) = splitAt (b - a - 1) (List.tail p2)
               in p1 ++ [xs List.!! b] ++ p3 ++ [xs List.!! a] ++ List.tail p4

    -- Concat the lists and repeat
    reduceRow matrix1 r = take r matrix2 ++ [row1] ++ nextrows
      where
        --First non-zero element on or below (r,r).
        firstnonzero = head $ filter (\x -> matrix1 List.!! x List.!! r /= 0) [r..length matrix1 - 1]
        --Matrix with row swapped (if needed)
        matrix2 = swap matrix1 r firstnonzero
        --Row we're working with
        row = matrix2 List.!! r
        --Make it have 1 as the leading coefficient
        row1 = (\x -> x *  recip (row List.!! r)) <$> row
        --Subtract nr from row1 while multiplying
        subrow nr = let k = nr List.!! r in zipWith (\a b -> k*a - b) row1 nr
        --Apply subrow to all rows below
        nextrows = subrow <$> drop (r + 1) matrix2


    fixlastrow matrix' = a ++ [List.init (List.init row) ++ [1, z * recip nz]]
      where
        a = List.init matrix'; row = List.last matrix'
        z = List.last row
        nz = List.last (List.init row)

-- Solve a matrix (must already be in REF form) by back substitution.
substituteMatrix :: (KnownNat p) => [[PrimeField p]] -> [PrimeField p]
substituteMatrix matrix = foldr next [List.last (List.last matrix)] (List.init matrix)
  where
    next row found = let
      subpart = List.init $ drop (length matrix - length found) row
      solution = List.last row - sum (zipWith (*) found subpart)
      in solution : found

solveLinearSystem :: (KnownNat p) => [[PrimeField p]] -> [PrimeField p]
solveLinearSystem = reverse . substituteMatrix . gaussianReduce

-------------------------
-- Arbitrary instances --
-------------------------

instance (KnownNat p) => Arbitrary (ArithCircuit (PrimeField p)) where
  arbitrary = do
    n <- choose (1, 100)
    m <- choose (1, n)
    arithCircuitGen n m

arithCircuitGen :: forall p. (KnownNat p) => Integer -> Integer -> Gen (ArithCircuit (PrimeField p))
arithCircuitGen n m = do
    -- TODO: Can lConstraints be a different value?
    let lConstraints = m

    cs <- vectorOf (fromIntegral m) arbitrary

    weights@GateWeights{..} <- gateWeightsGen lConstraints n
    let gateWeights = GateWeights wL wR wO

    commitmentWeights <- wvGen lConstraints m
    pure $ ArithCircuit gateWeights commitmentWeights cs
      where
        gateWeightsGen :: Integer -> Integer -> Gen (GateWeights (PrimeField p))
        gateWeightsGen lConstraints n = do
          let genVec = ((\i -> insertAt i (oneVector n) (replicate (fromIntegral lConstraints - 1) (zeroVector n))) <$> choose (0, fromIntegral lConstraints))
          wL <- genVec
          wR <- genVec
          wO <- genVec
          pure $ GateWeights wL wR wO

        wvGen :: Integer -> Integer -> Gen [[PrimeField p]]
        wvGen lConstraints m
          | lConstraints < m = panic "Number of constraints must be bigger than m"
          | otherwise = shuffle (genIdenMatrix m ++ genZeroMatrix (lConstraints - m) m)
        zeroVector x = replicate (fromIntegral x) 0
        oneVector x = replicate (fromIntegral x) 1


instance (KnownNat p) => Arbitrary (Assignment (PrimeField p)) where
  arbitrary = do
    n <- (arbitrary :: Gen Integer)
    arithAssignmentGen n

arithAssignmentGen :: (KnownNat p) => Integer -> Gen (Assignment (PrimeField p))
arithAssignmentGen n = do
    aL <- vectorOf (fromIntegral n) (fromInteger <$> choose (0, 2^n))
    aR <- vectorOf (fromIntegral n) (fromInteger <$> choose (0, 2^n))
    let aO = aL `hadamardp` aR
    pure $ Assignment aL aR aO

instance (KnownNat p) => Arbitrary (ArithWitness (PrimeField p)) where
  arbitrary = do
    n <- choose (1, 100)
    m <- choose (1, n)
    arithCircuit <- arithCircuitGen n m
    assignment <- arithAssignmentGen n
    arithWitnessGen assignment arithCircuit m

arithWitnessGen :: (KnownNat p) => Assignment (PrimeField p) -> ArithCircuit (PrimeField p) -> Integer -> Gen (ArithWitness (PrimeField p))
arithWitnessGen assignment arith@ArithCircuit{..} m = do
  commitBlinders <- vectorOf (fromIntegral m) arbitrary
  let vs = computeInputValues weights commitmentWeights assignment cs
      commitments = zipWith commit vs commitBlinders
  pure $ ArithWitness assignment commitments commitBlinders

