# ドラゴンキングダム — デプロイ手順

土地NFT（KingdomLand）とドラゴンNFT（KingdomDragon）を Sepolia テストネットで動かす手順です。本物のお金は使いません。

## 中身

| ファイル | 内容 |
|---|---|
| `contracts/DragonKingdom.sol` | 2つのNFTコントラクト（ERC-721） |
| `game/index.html` | 3Dゲーム画面（ウォレット接続対応、ファイル1つで動作） |

## 1. 準備

1. MetaMask をインストールし、ネットワークを **Sepolia** に切り替える
   （設定 → 詳細 → 「テストネットを表示」をオン）
2. faucet で Sepolia ETH を入手する（例：Google Cloud Web3 Faucet、Alchemy Sepolia Faucet）
   0.05 ETH ほどあれば十分です

## 2. コントラクトをデプロイ（Remix）

1. https://remix.ethereum.org を開く
2. 新しいファイル `DragonKingdom.sol` を作り、`contracts/DragonKingdom.sol` の中身を貼り付ける
   （OpenZeppelin の import は Remix が自動で読み込みます）
3. 左の「Solidity Compiler」でバージョン **0.8.24 以上** を選び、Compile
4. 左の「Deploy & Run」で Environment を **Injected Provider - MetaMask** にする
5. Contract で **KingdomLand** を選び Deploy → MetaMask で承認
   → 表示されたアドレスをメモ（これが LAND_ADDRESS）
6. Contract で **KingdomDragon** を選び、Deploy の横の欄に 5 のアドレスを入れて Deploy
   → このアドレスが DRAGON_ADDRESS

## 3. ゲーム画面を設定

`game/index.html` を開き、`CONFIG` の2つのアドレスを書き換えます。

```js
const CONFIG = {
  LAND_ADDRESS:   "0x…(KingdomLand のアドレス)",
  DRAGON_ADDRESS: "0x…(KingdomDragon のアドレス)",
  CHAIN_ID: 11155111,
  CHAIN_NAME: "Sepolia",
};
```

## 4. 公開して遊ぶ

ウォレット接続には https の普通のWebページが必要です。どれか1つで公開してください。

- **GitHub Pages**：リポジトリに `index.html` を置き、Settings → Pages で公開
- **Netlify Drop**：https://app.netlify.com/drop に `game` フォルダをドラッグ
- **Vercel**：フォルダをインポートするだけ

スマホでは **MetaMaskアプリ内のブラウザ** でそのURLを開き、「ウォレット接続」を押します。

## ゲームのルール（コントラクトで決まっていること）

- 土地：20×20＝400区画。1区画 0.001 ETH。tokenId = y × 20 + x
- 地形（草原・森・山・砂漠）は座標から自動で決まる
- ドラゴン：自分の土地でのみ孵化（0.002 ETH）。属性（炎・氷・雷・闇）とパワー（50〜149）はランダム
- 訓練：1時間に1回レベル+1。自分の別の土地へ移動可能
- OpenSea のテストネット版などで、どちらのNFTも属性つきで表示されます
- 価格はデプロイした人が `setLandPrice` / `setDragonPrice` で変更、売上は `withdraw` で引き出し

## メインネットに出す前に必要なこと

- 乱数を Chainlink VRF に置き換える（今は予測可能な簡易乱数）
- 専門家によるセキュリティ監査
- 画像（ドラゴンや土地のイラスト）を IPFS に置き、`tokenURI` に image を追加
- 利用規約や、地域ごとの法規制（NFT販売・景品表示など）の確認
