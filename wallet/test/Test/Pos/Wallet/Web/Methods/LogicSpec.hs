{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}

module Test.Pos.Wallet.Web.Methods.LogicSpec
       ( spec
       ) where

import           Universum

import           Test.Hspec (Spec, beforeAll_, describe)
import           Test.Hspec.QuickCheck (prop)

import           Pos.Chain.Genesis as Genesis (Config (..))
import           Pos.Core.NetworkMagic (NetworkMagic, makeNetworkMagic)
import           Pos.Util.Wlog (setupTestLogging)
import           Pos.Wallet.Web.Methods.Logic (getAccounts, getWallets)

import           Test.Pos.Configuration (withDefConfigurations)
import           Test.Pos.Util.QuickCheck.Property (stopProperty)
import           Test.Pos.Wallet.Web.Mode (WalletProperty)

-- TODO remove HasCompileInfo when MonadWalletWebMode will be splitted.
spec :: Spec
spec = beforeAll_ setupTestLogging $
            withDefConfigurations $ \genesisConfig _ _ ->
                describe "Pos.Wallet.Web.Methods" $ do
                    let nm = makeNetworkMagic $ configProtocolMagic genesisConfig
                    prop emptyWalletOnStarts (emptyWallet nm)
                  where
                    emptyWalletOnStarts = "wallet must be empty on start"

emptyWallet :: NetworkMagic -> WalletProperty ()
emptyWallet nm = do
    wallets <- lift (getWallets nm)
    unless (null wallets) $
        stopProperty "Wallets aren't empty"
    accounts <- lift $ getAccounts nm Nothing
    unless (null accounts) $
        stopProperty "Accounts aren't empty"
