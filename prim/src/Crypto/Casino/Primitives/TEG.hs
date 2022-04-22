--
-- implementation of:
--   2.2 (n-n)-Threshold ElGamal Cryptosystem
--
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeApplications #-}
module Crypto.Casino.Primitives.TEG
    ( SecretKey
    , PublicKey
    , PublicBroadcast
    , DecryptBroadcast
    , DecryptSharePoint
    , Ciphertext
    , JointPublicKey
    , Random
    , Message
    , debugHash
    , generation
    , randomNew
    , combine
    , combineVerify
    , reEncrypter
    , publicBroadcastVerify
    , ciphertextCreate
    , ciphertextAdd
    , ciphertextMul
    , ciphertextSum
    , ciphertextProduct
    , ciphertextScale
    , ciphertextToPoints
    , productCiphertextExponentiate
    , encryption
    , encryptionWith
    , encryptionRandom1
    , reRandomize
    , decryptProofVerify
    , decryptShare
    , decryptShareNoProof
    , verifiableDecrypt
    , verifiableDecryptOwn
    , integerToMessage
    , integerFromMessage
    , bilinearMap
    , properties
    ) where

import           Control.DeepSeq
import           Crypto.Random
import           Crypto.Casino.Primitives.ECC hiding (PrivateKey, PublicKey)
import           Crypto.Casino.Primitives.SSize
import           Crypto.Hash (Blake2b, Digest, hash)
import qualified Crypto.Casino.Primitives.DLOG as DLOG
import qualified Crypto.Casino.Primitives.DLEQ as DLEQ
import           Data.List (foldl', foldl1')
import           GHC.Generics
import           Basement.Sized.List (ListN)
import qualified Basement.Sized.List as ListN
import           Basement.Bounded

import           Foundation.Check
import qualified Data.ByteString as B

newtype PublicKey = PublicKey Point
    deriving (Show,Eq)
newtype SecretKey = SecretKey Scalar
    deriving (Show,Eq)

type Random = Scalar

newtype DecryptSharePoint = DecryptSharePoint Point
    deriving (Show,Eq,Generic)

instance NFData DecryptSharePoint

-- zk proof of this private key is associated with this public key without giving up the private key
type PublicBroadcast = (PublicKey, DLOG.Proof) 
type DecryptBroadcast = (DecryptSharePoint, DLEQ.Proof)

-- | Ciphertext under a joint key that include the random element and the ciphered value
data Ciphertext = Ciphertext Point Point
    deriving (Show,Eq,Generic)

-- | This is stricly used for printing for debug
debugHash :: Ciphertext -> String
debugHash (Ciphertext p1 p2) =
    show (hash (pointToBinary p1 `B.append` pointToBinary p2) :: Digest (Blake2b 32))

ciphertextToPoints :: Ciphertext -> (Point, Point)
ciphertextToPoints (Ciphertext a b) = (a,b)

instance SSize Ciphertext where
    type SizePoints Ciphertext = 2
    type SizeScalar Ciphertext = 0

instance NFData Ciphertext

type Message = Point

newtype JointPublicKey = JointPublicKey Point
    deriving (Show,Eq,Generic,Arbitrary)

instance NFData JointPublicKey

data HomomorphicTest = HomomorphicTest Point Point Point Point
    deriving (Show,Eq)

instance Arbitrary HomomorphicTest where
    arbitrary = HomomorphicTest <$> arbitrary <*> arbitrary
                                <*> arbitrary <*> arbitrary

instance Arbitrary Ciphertext where
    arbitrary = Ciphertext <$> arbitrary <*> arbitrary

-- koblitz probabilistic encoding/decoding k parameter
k :: Integer
k = 7919

integerFromMessage :: Message -> Integer
integerFromMessage = koblitzDecode . pointToX
  where
    koblitzDecode x = (x - 1) `div` k

-- maximum integer number is ((p-1)/2) / k
integerToMessage :: Integer -> Message
integerToMessage n = koblitzEncode (n * k + 1)
  where
    upperLimit = (n+1) * k
    -- probability of failure to find a sqrt is extremely small considering k : 1 / (2^k)
    koblitzEncode i
        | i == upperLimit = error "integerToMessage: cannot find a valid message"
        | otherwise       =
            case pointFromX i of
                Just p  -> p
                Nothing -> koblitzEncode (i+1)

randomNew :: MonadRandom random => random Random
randomNew = keyGenerate

generation :: MonadRandom random => random (PublicBroadcast, SecretKey)
generation = addPublicBroadcast <$> (SecretKey <$> keyGenerate)
                                <*> keyGenerate
  where
    addPublicBroadcast :: SecretKey -> Random -> (PublicBroadcast, SecretKey)
    addPublicBroadcast sk@(SecretKey skVal) dlogR = ((PublicKey hi, dlog), sk)
          where
            dlog = DLOG.generate dlogR skVal (DLOG.DLOG curveGenerator hi)
            hi = pointFromSecret skVal

publicBroadcastVerify :: PublicBroadcast -> Bool
publicBroadcastVerify (PublicKey pk, dlog) = DLOG.verify (DLOG.DLOG curveGenerator pk) dlog

combine :: [PublicBroadcast] -> JointPublicKey
combine l = JointPublicKey $ foldl' (.+) pointIdentity $ map (pubKeyToPoint . fst) l
  where pubKeyToPoint (PublicKey p) = p

combineVerify :: [PublicBroadcast] -> Maybe JointPublicKey
combineVerify l
    | and $ fmap publicBroadcastVerify l = Just $ combine l
    | otherwise                          = Nothing

encryption :: MonadRandom random => JointPublicKey -> Message -> random Ciphertext
encryption pk msg = encryptionWith pk msg <$> keyGenerate

encryptionWith :: JointPublicKey -> Message -> Random -> Ciphertext
encryptionWith (JointPublicKey pk) msg r = Ciphertext c1 c2
  where c1 = pointFromSecret r
        c2 = (pk .* r) .+ msg

-- | Encrypt with a deterministic random equal 1
encryptionRandom1 :: JointPublicKey -> Message -> Ciphertext
encryptionRandom1 jpk msg =
    encryptionWith jpk msg (keyFromNum 1)

reEncrypter :: JointPublicKey -> Random -> Ciphertext
reEncrypter jpk = encryptionWith jpk pointIdentity

reRandomize :: JointPublicKey -> Random -> Ciphertext -> Ciphertext
reRandomize jpk r c = reEncrypter jpk r `ciphertextMul` c

decryptShare :: MonadRandom random
             => SecretKey
             -> Ciphertext
             -> random DecryptBroadcast
decryptShare (SecretKey sk) (Ciphertext c1 _) = toDecryptBroadcast <$> keyGenerate
  where
    !d = c1 .* sk
    pk = pointFromSecret sk
    toDecryptBroadcast dleqR =
        (DecryptSharePoint d, DLEQ.generate dleqR sk (DLEQ.DLEQ curveGenerator pk c1 d))

-- | Verify if a decrypt broadcast associated with a ciphertext and a public key
-- is correct
decryptProofVerify :: Ciphertext
                   -> PublicKey
                   -> DecryptBroadcast
                   -> Bool
decryptProofVerify (Ciphertext c1 _) (PublicKey pk) (DecryptSharePoint di, dleq) =
    DLEQ.verify (DLEQ.DLEQ curveGenerator pk c1 di) dleq

decryptShareNoProof :: SecretKey
                    -> Ciphertext
                    -> DecryptSharePoint
decryptShareNoProof (SecretKey sk) (Ciphertext c1 _) = DecryptSharePoint d where !d = c1 .* sk

verifiableDecrypt :: [(PublicKey, DecryptBroadcast)] -- ^ decrypt broadcast associated with their public key
                  -> Ciphertext
                  -> Maybe Message
verifiableDecrypt decrypts c@(Ciphertext c1 c2)
    | allVerify = Just (c2 .- sumds)
    | otherwise = Nothing
  where
    allVerify = and $ map (uncurry (decryptProofVerify c)) decrypts
    sumds = sumDecryptSharePoints $ map (fst . snd) decrypts

sumDecryptSharePoints :: [DecryptSharePoint] -> Point
sumDecryptSharePoints = foldl1' (.+) . map (\(DecryptSharePoint p) -> p)

verifiableDecryptOwn :: DecryptSharePoint
                     -> [(PublicKey, DecryptBroadcast)]
                     -> Ciphertext
                     -> Maybe Message
verifiableDecryptOwn (DecryptSharePoint selfP) decrypts ct =
    case verifiableDecrypt decrypts ct of
        Nothing -> Nothing
        Just m  -> Just (m .- selfP)

ciphertextCreate :: Scalar -> Point -> Ciphertext
ciphertextCreate a b = Ciphertext (pointFromSecret a) b

ciphertextAdd :: Ciphertext -> Ciphertext -> Ciphertext
ciphertextAdd (Ciphertext c1a c1b) (Ciphertext c2a c2b) = Ciphertext (c1a .+ c2a) (c1b .+ c2b)
{-# DEPRECATED ciphertextAdd "use ciphertextMul" #-}

ciphertextMul :: Ciphertext -> Ciphertext -> Ciphertext
ciphertextMul (Ciphertext c1a c1b) (Ciphertext c2a c2b) = Ciphertext (c1a .+ c2a) (c1b .+ c2b)

ciphertextScale :: Scalar -> Ciphertext -> Ciphertext
ciphertextScale s (Ciphertext c1 c2) = Ciphertext (c1 .* s) (c2 .* s)

ciphertextIdentity :: Ciphertext
ciphertextIdentity = Ciphertext pointIdentity pointIdentity

ciphertextSum :: [Ciphertext] -> Ciphertext
ciphertextSum = foldl' ciphertextAdd ciphertextIdentity
{-# DEPRECATED ciphertextSum "use ciphertextProduct" #-}

ciphertextProduct :: [Ciphertext] -> Ciphertext
ciphertextProduct = foldl' ciphertextAdd ciphertextIdentity

productCiphertextExponentiate :: ListN n Ciphertext -> ListN n Scalar -> Ciphertext
productCiphertextExponentiate =
      ((ciphertextProduct . ListN.unListN) .)
    . ListN.zipWith (flip ciphertextScale)

bilinearMap :: ListN n Ciphertext -> ListN n Scalar -> Ciphertext
bilinearMap = productCiphertextExponentiate

newtype KoblitzEncodingInteger = KoblitzEncodingInteger Integer
    deriving (Show,Eq)

instance Arbitrary KoblitzEncodingInteger where
    arbitrary = KoblitzEncodingInteger . (+ 1) . toInteger . unZn <$> (arbitrary :: Gen (Zn 10000))

properties :: Test
properties = Group "TEG"
    [ Group "math"
        [ Property "eq" $ \(x :: Ciphertext) -> x == x
        , Property "right-identity" $ \x -> (x `ciphertextAdd` ciphertextIdentity) == x
        , Property "left-identity" $ \x -> (ciphertextIdentity `ciphertextAdd` x) == x
        , Property "commutative" $ \x1 x2 -> (x1 `ciphertextAdd` x2) == (x2 `ciphertextAdd` x1)
        , Property "associative" $ \x1 x2 x3 ->
            (x1 `ciphertextAdd` x2) `ciphertextAdd` x3 == x1 `ciphertextAdd` (x2 `ciphertextAdd` x3)
        , Property "scale-x2" $ \x -> ciphertextScale (keyFromNum 2) x == (x `ciphertextAdd` x)
        , Property "scale-x3" $ \x -> ciphertextScale (keyFromNum 3) x == ((x `ciphertextAdd` x) `ciphertextAdd` x)
        ]
    , Group "homomorphic"
        [ Property "plus" $ \m1 m2 p1 p2 ->
            Ciphertext (m1 .+ m2) (p1 .+ p2) == ciphertextMul (Ciphertext m1 p1) (Ciphertext m2 p2)
        , Property "scale" $ \m1 p1 s ->
            Ciphertext (m1 .* s) (p1 .* s) == ciphertextScale s (Ciphertext m1 p1)
        , Property "scale-commutative" $ \m1 p1 s1 s2 ->
            let ct = Ciphertext m1 p1
             in (ciphertextScale s1 . ciphertextScale s2) ct == (ciphertextScale s2 . ciphertextScale s1) ct
        -- , Property "scale2" $ \m1 p1 s1 ->
        --     Ciphertext (m1 .* (s1 #+ keyFromNum 1)) (p1 .* (s1 #+ keyFromNum 1)) == (ciphertextScale s1 . ciphertextScale (keyFromNum 1)) (Ciphertext m1 p1)
        ]
    , Group "koblitz-probabilitistic"
        [ Property "decode . encode" $ \(KoblitzEncodingInteger i) ->
            integerFromMessage (integerToMessage i) == i
        ]
    , Group "encrypt-decrypt"
        [ Property "encrypt-1" $ \drg (KoblitzEncodingInteger i) ->
            fst $ withDRG (drgNewTest drg) $ do
                let msg = integerToMessage i
                (pb, sk) <- generation
                let jpk = maybe (error "cannot verify") id $ combineVerify [pb]
                c <- encryption jpk msg
                db <- decryptShare sk c
                let mmsg = verifiableDecrypt [(fst pb, db)] c
                pure $ Just msg === mmsg 
        , Property "encrypt-2" $ \drg (KoblitzEncodingInteger i) ->
            fst $ withDRG (drgNewTest drg) $ do
                let msg = integerToMessage i
                (pb1, sk1) <- generation
                (pb2, sk2) <- generation

                let jpk = maybe (error "cannot verify") id $ combineVerify [pb1,pb2]

                c <- encryption jpk msg

                db1 <- decryptShare sk1 c
                db2 <- decryptShare sk2 c
                let mmsg = verifiableDecrypt [(fst pb1, db1), (fst pb2, db2)] c
                pure $ Just msg === mmsg 
        , Property "encrypt-3" $ \drg (KoblitzEncodingInteger i) ->
            fst $ withDRG (drgNewTest drg) $ do
                let msg = integerToMessage i
                (pb1, sk1) <- generation
                (pb2, sk2) <- generation
                (pb3, sk3) <- generation

                let jpk = maybe (error "cannot verify") id $ combineVerify [pb1,pb2,pb3]

                c <- encryption jpk msg

                db1 <- decryptShare sk1 c
                db2 <- decryptShare sk2 c
                db3 <- decryptShare sk3 c
                let mmsg = verifiableDecrypt [(fst pb1, db1), (fst pb2, db2), (fst pb3, db3)] c
                let mm1 = verifiableDecryptOwn (fst db1) [(fst pb2, db2), (fst pb3, db3)] c
                let mm2 = verifiableDecryptOwn (fst db2) [(fst pb1, db1), (fst pb3, db3)] c
                let mm3 = verifiableDecryptOwn (fst db3) [(fst pb1, db1), (fst pb2, db2)] c
                pure $ (Just msg === mmsg) `propertyAnd` (Just msg === mm1) `propertyAnd` (Just msg === mm2) `propertyAnd` (Just msg === mm3)
        ]
    ]
