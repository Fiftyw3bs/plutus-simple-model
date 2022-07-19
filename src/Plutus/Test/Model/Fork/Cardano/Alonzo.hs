module Plutus.Test.Model.Fork.Cardano.Alonzo(
  Era,
  toAlonzoTx,
  fromTxId,
  toAddr,
  toValue,
  toTxOut,
  toTxIn,
  toUtxo,
) where

import Prelude

import Control.Monad

import Data.Map qualified as Map
import Data.Maybe (mapMaybe)
import Data.Sequence.Strict qualified as Seq
import Data.Set qualified as Set
import Data.Bifunctor
import Data.ByteString qualified as BS
import Cardano.Ledger.BaseTypes
import Cardano.Ledger.TxIn qualified as C
import Cardano.Ledger.Crypto (StandardCrypto)
import Cardano.Ledger.Alonzo (AlonzoEra, PParams)
import Cardano.Ledger.Alonzo.Data qualified as C
import Cardano.Ledger.Alonzo.Tx qualified as C
import Cardano.Ledger.Alonzo.TxBody qualified as C
import Cardano.Ledger.Credential qualified as C
import Cardano.Ledger.Keys qualified as C
import Cardano.Ledger.Address qualified as C
import Cardano.Ledger.Slot qualified as C
import Cardano.Ledger.Compactible qualified as C
import Cardano.Ledger.CompactAddress qualified as C
import Cardano.Ledger.SafeHash qualified as C (hashAnnotated)
import Cardano.Ledger.Shelley.UTxO qualified as C
import Cardano.Ledger.Shelley.API.Types qualified as C (
  StrictMaybe(..),
  )
import Cardano.Ledger.Alonzo.PParams qualified as C
import Cardano.Ledger.Alonzo.Scripts qualified as C
import Cardano.Ledger.Alonzo.TxWitness qualified as C
import Cardano.Ledger.Alonzo.Language qualified as C
import qualified Cardano.Crypto.Hash.Class as Crypto
import Plutus.Test.Model.Fork.TxExtra qualified as P
import Plutus.V2.Ledger.Api qualified as P
import Plutus.V2.Ledger.Tx qualified as P
import Plutus.V2.Ledger.Tx qualified as Plutus
import PlutusTx.Builtins.Internal qualified as P
import PlutusTx.Builtins qualified as PlutusTx
import Plutus.Test.Model.Fork.Ledger.Tx qualified as Plutus
import Plutus.Test.Model.Fork.Ledger.Scripts qualified as C (datumHash, validatorHash, toScript)
import Plutus.Test.Model.Fork.Cardano.Common(
  getInputsBy,
  getFee,
  getInterval,
  getMint,
  getDCerts,
  getWdrl,
  toValue,
  toScriptHash,
  toCredential,
  toTxIn,
  )
import Cardano.Ledger.SafeHash
import Cardano.Crypto.Hash.Class
import Data.ByteString.Short (fromShort)

type Era = AlonzoEra StandardCrypto
type ToCardanoError = String

toAlonzoTx :: Network -> PParams Era -> P.Tx -> Either ToCardanoError (C.ValidatedTx Era)
toAlonzoTx network params tx = do
  body <- toBody
  wits <- toWits body
  let isValid = C.IsValid True -- TODO or maybe False
      auxData = C.SNothing
  pure $ C.ValidatedTx body wits isValid auxData
  where
    toBody = do
      inputs <- getInputsBy Plutus.txInputs tx
      collateral <- getInputsBy Plutus.txCollateral tx
      outputs <- getOutputs tx
      txcerts <- getDCerts network (C._poolDeposit params) (C._minPoolCost params) tx
      txwdrls <- getWdrl network tx
      let txfee = getFee tx
          txvldt = getInterval tx
          txUpdates = C.SNothing
          reqSignerHashes = getSignatories tx
      mint <- getMint tx
      let scriptIntegrityHash = C.SNothing
          adHash = C.SNothing
          txnetworkid = C.SJust network
      pure $
        C.TxBody
          inputs
          collateral
          outputs
          txcerts
          txwdrls
          txfee
          txvldt
          txUpdates
          reqSignerHashes
          mint
          scriptIntegrityHash
          adHash
          txnetworkid


    getOutputs =
        fmap Seq.fromList
      . mapM (toTxOut network)
      . Plutus.txOutputs
      . P.tx'plutus


    getSignatories =
        Set.fromList
      . fmap (C.hashKey . C.vKey)
      . Map.elems
      . Plutus.txSignatures
      . P.tx'plutus



    toWits txBody = do
      let keyWits = Set.fromList $ fmap (C.makeWitnessVKey txBodyHash) $ Map.elems $ Plutus.txSignatures $ P.tx'plutus tx
          bootstrapWits = mempty
      scriptWits <- fmap Map.fromList $ mapM (\(sh, s) -> (, C.toScript C.PlutusV1 s) <$> toScriptHash sh) allScripts
      datumWits1 <- fmap Map.fromList $ mapM (\d -> (, toDatum d) <$> (toDataHash $ C.datumHash d)) validatorDatums1
      datumWits2 <- fmap Map.fromList $ mapM (\(dh, d) -> (, toDatum d) <$> toDataHash dh) validatorDatums2
      let datumWits = C.TxDats $ datumWits1 <> datumWits2
      let redeemerWits = C.Redeemers $ mintRedeemers <> inputRedeemers <> certRedeemers <> withdrawRedeemers
      pure $ C.TxWitness keyWits bootstrapWits scriptWits datumWits redeemerWits
      where
        txBodyHash = C.hashAnnotated txBody

        allScripts = fmap addHash $ mints <> withdraws <> validators <> certificates
          where
            mints = fmap P.getMintingPolicy $ Set.toList $ Plutus.txMintScripts $ P.tx'plutus tx
            withdraws = mapMaybe (fmap (P.getStakeValidator . snd) . P.withdraw'script) (P.extra'withdraws $ P.tx'extra tx)
            certificates = mapMaybe (fmap (P.getStakeValidator . snd) . P.certificate'script) (P.extra'certificates $ P.tx'extra tx)
            validators = fmap (\(script, _, _) -> script) validatorInfo

            addHash script = (C.validatorHash (P.Validator script), script)

        validatorInfo = mapMaybe (fromInType <=< P.txInType) (Set.toList $ Plutus.txInputs $ P.tx'plutus tx)

        validatorDatums1 = fmap (\(_,_,datum) -> datum) validatorInfo
        validatorDatums2 = Map.toList $ Plutus.txData $ P.tx'plutus tx

        fromInType = \case
          P.ConsumeScriptAddress (P.Validator script) redeemer datum -> Just (script, redeemer, datum)
          _ -> Nothing


        mintRedeemers =
          Map.fromList
          $ fmap (\(P.RedeemerPtr _tag n, redm) -> (C.RdmrPtr C.Mint (fromInteger n), addDefaultExUnits $ toRedeemer redm))
          $ filter (isMint . fst) $ Map.toList $ Plutus.txRedeemers $ P.tx'plutus tx
          where
            isMint = \case
              P.RedeemerPtr Plutus.Mint _ -> True
              _                           -> False

        inputRedeemers =
          Map.fromList
          $ mapMaybe toInput
          $ zip [0..] $ Set.toList
          $ Plutus.txInputs $ P.tx'plutus tx
          where
            toInput (n, tin) =
              case  P.txInType tin of
                Just (P.ConsumeScriptAddress _validator redeemer _datum) ->
                  Just (C.RdmrPtr C.Spend (fromInteger n), addDefaultExUnits $ toRedeemer redeemer)
                _ -> Nothing

        certRedeemers = redeemersBy C.Cert (fmap P.certificate'script . P.extra'certificates)
        withdrawRedeemers = redeemersBy C.Rewrd (fmap P.withdraw'script . P.extra'withdraws)

        redeemersBy :: C.Tag -> (P.Extra -> [Maybe (P.Redeemer, a)]) -> Map.Map C.RdmrPtr (C.Data Era, C.ExUnits)
        redeemersBy scriptTag extract =
          Map.fromList
          $ mapMaybe toWithdraw
          $ zip [0..]
          $ extract $ P.tx'extra tx
          where
            toWithdraw (n, ws) = flip fmap ws $ \(redeemer, _script) ->
              (C.RdmrPtr scriptTag (fromInteger n), addDefaultExUnits $ toRedeemer redeemer)

        addDefaultExUnits rdm = (rdm, C.ExUnits 1 1)



fromTxId :: C.TxId StandardCrypto -> P.TxId
fromTxId (C.TxId safeHash) =
  case extractHash safeHash of
    UnsafeHash shortBs -> P.TxId $ P.BuiltinByteString $ fromShort shortBs

-- toTxIn :: P.TxOutRef -> Either ToCardanoError (C.TxIn StandardCrypto)

toUtxo :: Network -> [(P.TxOutRef, P.TxOut)] -> Either ToCardanoError (C.UTxO Era)
toUtxo network xs = C.UTxO . Map.fromList <$> mapM go xs
  where
    go (tin, tout) = do
      tinC <- toTxIn tin
      toutC <- toTxOut network tout
      pure (tinC, toutC)

toTxOut :: Network -> P.TxOut -> Either ToCardanoError (C.TxOut Era)
toTxOut network (P.TxOut addr value mdh _) = do
  caddr <- toAddr network addr
  cvalue <- toValue value
  fullValue caddr cvalue
{- TODO: implement compact case
  case cvalue of
    C.Value ada [] ->
      case C.toCompact (Coin ada) of
        Just compactAda ->
          case caddr of
            C.Addr network cred C.StakeRefNull ->
              let addr28 = snd $ C.encodeAddress28 netw cred
              in  adaOnly addr28 compactAda
            _ -> fullValue caddr cvalue
        Nothing         -> fullValue caddr cvalue
    _              -> fullValue caddr cvalue
-}
  where
    {-
    adaOnly (C.Addr netw pred cred) ada = do
      let addr28 = snd $ C.encodeAddress28 netw cred
      case mdh of
        Nothing -> pure $ C.TxOut_AddrHash28_AdaOnly cred addr28 ada
        Just dh -> do
           mdh32 <- C.encodeDataHash32 <$> toDataHash dh
           case mdh32 of
              Nothing   -> Left "failed to encode data hash 32"
              Just dh32 -> pure $ C.TxOut_AddrHash28_AdaOnly_DataHash32 cred addr28 ada dh32
        -}

    fullValue caddr cvalue = do
      cval <- toVal cvalue
      case mdh of
        Plutus.OutputDatumHash dh -> do
          cdh <- toDataHash dh
          pure $ C.TxOutCompactDH' compAddr cval cdh
        Plutus.NoOutputDatum -> pure $ C.TxOutCompact' compAddr cval
        Plutus.OutputDatum _ -> Left "Output datum not supported in alonzo era"
      where
        compAddr = C.compactAddr caddr

        toVal v =
          case C.toCompact v of
            Just cval -> Right cval
            Nothing   -> Left "Fail to create compact value"


toDataHash :: P.DatumHash -> Either ToCardanoError (C.DataHash StandardCrypto)
toDataHash (P.DatumHash bs) =
  let bsx = PlutusTx.fromBuiltin bs
      tg = "toDatumHash (" <> show (BS.length bsx) <> " bytes)"
  in tag tg $ maybe (Left "Failed to get TxId Hash") Right $ unsafeMakeSafeHash <$> Crypto.hashFromBytes bsx

toAddr :: Network -> P.Address -> Either ToCardanoError (C.Addr StandardCrypto)
toAddr network (P.Address addressCredential addressStakingCredential) =
  C.Addr network <$> toCredential addressCredential <*> toStakeAddressReference addressStakingCredential

toStakeAddressReference :: Maybe P.StakingCredential -> Either ToCardanoError (C.StakeReference StandardCrypto)
toStakeAddressReference = \case
  Nothing -> pure C.StakeRefNull
  Just (P.StakingHash stakeCred) -> C.StakeRefBase <$> toCredential stakeCred
  Just (P.StakingPtr x y z)      -> pure $ C.StakeRefPtr $ C.Ptr (C.SlotNo $ fromIntegral x) (TxIx $ fromIntegral y) (CertIx $ fromIntegral z)

toDatum :: P.Datum -> C.Data Era
toDatum (P.Datum (P.BuiltinData d)) = C.Data d

toRedeemer :: P.Redeemer -> C.Data Era
toRedeemer (P.Redeemer (P.BuiltinData d)) = C.Data d

tag :: String -> Either ToCardanoError t -> Either ToCardanoError t
tag s = first (\x -> "tag " <> s <> " :" <> x)

