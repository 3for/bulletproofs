{-# LANGUAGE NamedFieldPuns, MultiWayIf #-}

module Bulletproofs.InnerProductProof.Prover (
  generateProof,
) where

import Protolude

import Control.Exception (assert)
import qualified Data.List as L
import qualified Data.Map as Map

import qualified Crypto.PubKey.ECC.Types as Crypto
import PrimeField (PrimeField(..), toInt)

import Bulletproofs.Curve
import Bulletproofs.Utils

import Bulletproofs.InnerProductProof.Internal

-- | Generate proof that a witness l, r satisfies the inner product relation
-- on public input (Gs, Hs, h)
generateProof
  :: KnownNat p
  => InnerProductBase    -- ^ Generators Gs, Hs, h
  -> Crypto.Point
  -- ^ Commitment P = A + xS − zG + (z*y^n + z^2 * 2^n) * hs' of vectors l and r
  -- whose inner product is t
  -> InnerProductWitness (PrimeField p)
  -- ^ Vectors l and r that hide bit vectors aL and aR, respectively
  -> InnerProductProof (PrimeField p)
generateProof productBase commitmentLR witness
  = generateProof' productBase commitmentLR witness [] []

generateProof'
  :: KnownNat p
  => InnerProductBase
  -> Crypto.Point
  -> InnerProductWitness (PrimeField p)
  -> [Crypto.Point]
  -> [Crypto.Point]
  -> InnerProductProof (PrimeField p)
generateProof'
  InnerProductBase{ bGs, bHs, bH }
  commitmentLR
  InnerProductWitness{ ls, rs }
  lCommits
  rCommits
  = case (ls, rs) of
    ([], [])   -> InnerProductProof [] [] 0 0
    ([l], [r]) -> InnerProductProof (reverse lCommits) (reverse rCommits) l r
    _          -> assert (checkLGs && checkRHs && checkLBs && checkC && checkC')
                $ generateProof'
                    InnerProductBase { bGs = gs'', bHs = hs'', bH = bH }
                    commitmentLR'
                    InnerProductWitness { ls = ls', rs = rs' }
                    (lCommit:lCommits)
                    (rCommit:rCommits)
  where
    n' = fromIntegral $ length ls
    nPrime = n' `div` 2

    (lsLeft, lsRight) = splitAt nPrime ls
    (rsLeft, rsRight) = splitAt nPrime rs
    (gsLeft, gsRight) = splitAt nPrime bGs
    (hsLeft, hsRight) = splitAt nPrime bHs

    cL = dot lsLeft rsRight
    cR = dot lsRight rsLeft

    lCommit = sumExps lsLeft gsRight
         `addP`
         sumExps rsRight hsLeft
         `addP`
         (cL `mulP` bH)

    rCommit = sumExps lsRight gsLeft
         `addP`
         sumExps rsLeft hsRight
         `addP`
         (cR `mulP` bH)

    x = shamirX' commitmentLR lCommit rCommit

    xInv = recip x
    xs = replicate nPrime x
    xsInv = replicate nPrime xInv

    gs'' = zipWith (\(exp0, pt0) (exp1, pt1) -> addTwoMulP exp0 pt0 exp1 pt1) (zip xsInv gsLeft) (zip xs gsRight)
    hs'' = zipWith (\(exp0, pt0) (exp1, pt1) -> addTwoMulP exp0 pt0 exp1 pt1) (zip xs hsLeft) (zip xsInv hsRight)

    ls' = ((*) x <$> lsLeft) ^+^ ((*) xInv <$> lsRight)
    rs' = ((*) xInv <$> rsLeft) ^+^ ((*) x <$> rsRight)

    commitmentLR'
      = ((x ^ 2) `mulP` lCommit)
        `addP`
        ((xInv ^ 2) `mulP` rCommit)
        `addP`
        commitmentLR

    -----------------------------
    -- Checks
    -----------------------------

    aL' = sumExps lsLeft gsRight
    aR' = sumExps lsRight gsLeft

    bL' = sumExps rsLeft hsRight
    bR' = sumExps rsRight hsLeft

    z = dot ls rs
    z' = dot ls' rs'

    lGs = sumExps ls bGs
    rHs = sumExps rs bHs

    lGs' = sumExps ls' gs''
    rHs' = sumExps rs' hs''

    checkLGs
      = lGs'
        ==
        sumExps ls bGs
        `addP`
        ((x ^ 2) `mulP` aL')
        `addP`
        ((xInv ^ 2) `mulP` aR')

    checkRHs
      = rHs'
        ==
        sumExps rs bHs
        `addP`
        ((x ^ 2) `mulP` bR')
        `addP`
        ((xInv ^ 2) `mulP` bL')

    checkLBs
      = dot ls' rs'
        ==
        dot ls rs + (x ^ 2) * cL + (xInv ^ 2) * cR

    checkC
      = commitmentLR
        ==
        (z `mulP` bH)
        `addP`
        lGs
        `addP`
        rHs

    checkC'
      = commitmentLR'
        ==
        (z' `mulP` bH)
        `addP`
        lGs'
        `addP`
        rHs'
