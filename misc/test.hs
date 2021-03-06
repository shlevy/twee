{-# LANGUAGE TemplateHaskell, FlexibleInstances, FlexibleContexts, UndecidableInstances, StandaloneDeriving, ScopedTypeVariables, TupleSections, DeriveGeneric #-}
import Twee.Constraints
import Twee.Term hiding (subst, canonicalise, F)
import Twee.Term.Core hiding (F)
import Test.QuickCheck hiding (Function, Fun)
import Test.QuickCheck.All
import Twee.Pretty
import Twee.CP
import Twee.Proof
import qualified Twee.KBO as Ord
import Text.PrettyPrint
import Twee.Base hiding (F)
import Twee.Rule
import Twee.Equation
import Control.Monad
import qualified Data.Map as Map
import Data.Maybe
import Data.Ord
import Data.List
import Data.Typeable
import qualified Twee.Index as Index
import Data.Int
import GHC.Generics

newtype Func = F Int deriving (Eq, Ord, Show)

instance Pretty Func where pPrint (F f) = text "f" <> int f
instance PrettyTerm Func
instance Arbitrary (Subst Func) where
  arbitrary = fmap fromJust (fmap listToSubst (liftM2 zip (fmap nub arbitrary) (infiniteListOf arbitrary)))
instance Arbitrary Func where
  arbitrary = F <$> choose (1, 1)
instance Minimal Func where
  minimal = fun (F 0)
instance Sized Func where size _ = 1
instance Arity Func where
  arity (F 0) = 0
  arity (F 1) = 2
instance Skolem Func
instance EqualsBonus Func

instance Arbitrary Var where arbitrary = fmap V (choose (0, 3))
instance (Ord f, Typeable f, Arbitrary f) => Arbitrary (Fun f) where
  arbitrary = fmap fun arbitrary

instance (Ord f, Typeable f, Arbitrary f, Sized f, Arity f) => Arbitrary (Term f) where
  arbitrary =
    sized $ \n ->
      oneof $
        [ build <$> var <$> arbitrary ] ++
        [ do { f <- arbitrary; build <$> app f <$> vectorOf (arity f) (resize ((n-1) `div` arity f) arbitrary :: Gen (Term f)) } | n > 0 ]
  shrink (App f ts0) =
    ts ++ (build <$> app f <$> shrinkOne ts)
    where
      ts = unpack ts0
      shrinkOne [] = []
      shrinkOne (x:xs) =
        [ y:xs | y <- shrink x ] ++
        [ x:ys | ys <- shrinkOne xs ]
  shrink _ = []

data Pair f = Pair (Term f) (Term f) deriving Show

instance (Ord f, Typeable f, Arbitrary f, Arity f, Sized f) => Arbitrary (Pair f) where
  arbitrary = liftM2 Pair arbitrary arbitrary
  shrink (Pair x y) =
    [ Pair x' y  | x' <- shrink x ] ++
    [ Pair x y'  | y' <- shrink y ] ++
    [ Pair x' y' | x' <- shrink x, y' <- shrink y ]

instance Ordered Func where
  lessIn = Ord.lessIn
  lessEq = Ord.lessEq

instance Function f => Arbitrary (Model f) where
  arbitrary = fmap (modelFromOrder . map Variable . nub) arbitrary
  shrink = weakenModel

prop_1 :: Model Func -> Pair Func -> Subst Func -> Property
prop_1 model (Pair t u) sub =
  counterexample ("Model: " ++ prettyShow model) $
  counterexample ("Subst: " ++ prettyShow sub) $
  conjoin $ do
    let cp = CriticalPair (t :=: u) 0 Nothing (axiom (Axiom 0 "dummy" (t :=: u)))
    r@(Rule _ t' u') <- map orient (map cp_eqn (split cp))
    return $
      counterexample ("LHS:   " ++ prettyShow t') $
      counterexample ("RHS:   " ++ prettyShow u') $
      counterexample ("Rule:  " ++ prettyShow r) $
      counterexample ("Inst:  " ++ prettyShow (Rule Oriented (subst sub t') (subst sub u'))) $
      counterexample ("Res:   " ++ show (lessIn model (subst sub u') (subst sub t'))) $
      not (reducesInModel model r sub) || isJust (lessIn model (subst sub u') (subst sub t'))

prop_2 :: Model Func -> Pair Func -> Bool
prop_2 model (Pair t u) =
  not (lessIn model t u == Just Strict && isJust (lessIn model u t))

prop_3 :: Pair Func -> Bool
prop_3 (Pair t u) =
  not (lessThan t u && lessEq u t)

prop_4 :: Pair Func -> Property
prop_4 (Pair t u) =
  t /= u ==> 
  not (lessEq t u && lessEq u t)

prop_5 :: Term Func -> Property
prop_5 t =
  lessEq t t .&&. not (lessThan t t)

prop_paths :: Term Func -> Property
prop_paths t =
  forAllShrink (choose (0, len t-1)) shrink $ \n ->
    counterexample (show (positionToPath t n)) $
    pathToPosition t (positionToPath t n) === n

deriving instance Ord f => Ord (Subst f)

prop_index :: [Term Func] -> Term Func -> Property
prop_index ts u =
  counterexample (show ts) $
  counterexample (show idx) $
  sort (catMaybes [fmap (,t) (match t u) | t <- ts]) ===
  sort (Index.matches u idx)
  where
    idx = foldr (\t -> Index.insert t t) Index.empty ts

deriving instance Eq Symbol
deriving instance Generic Symbol

instance Arbitrary Symbol where
  arbitrary =
    Symbol <$>
      arbitrary <*>
      fmap getLarge arbitrary <*>
      (fmap (fromIntegral . getLarge) (arbitrary :: Gen (Large Int32)) `suchThat` (> 0) `suchThat` (< 2^31))
  shrink s =
    filter ok (genericShrink s)
    where
      ok s = Twee.Term.Core.size s > 0

prop_symbol_1 :: Symbol -> Property
prop_symbol_1 s =
  withMaxSuccess 100000 $
  counterexample ("fun/index/size = " ++ show (isFun s, index s, Twee.Term.Core.size s)) $
  counterexample ("n = " ++ show (fromSymbol s)) $
  toSymbol (fromSymbol s) === twiddle s
  where
    twiddle s =
      s { index = fromIntegral (fromIntegral (index s) :: Int32) }

prop_symbol_2 :: Int64 -> Property
prop_symbol_2 n =
  withMaxSuccess 100000 $
  fromSymbol (toSymbol n) === n

return []
main = $forAllProperties (quickCheckWithResult stdArgs { maxSuccess = 1000000 })

t :: Term Func
t = build (app (fun (F 0)) [app (fun (F 1)) [var (V 0), var (V 1)], var (V 2)])
