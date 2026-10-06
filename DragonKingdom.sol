// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
 * Dragon Kingdom — 土地NFT と ドラゴンNFT
 * ------------------------------------------------------------
 * ・KingdomLand  : 20×20 マスの土地 (ERC-721)。tokenId = y * 20 + x
 * ・KingdomDragon: ドラゴン (ERC-721)。自分の土地に配置・訓練できる
 *
 * デプロイ順: 1) KingdomLand  2) KingdomDragon(土地コントラクトのアドレス)
 * テストネット (Sepolia) 用のプロトタイプです。乱数は簡易的なもので、
 * 本番 (メインネット) では Chainlink VRF などに置き換えてください。
 */

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";

/* ============================================================
 *  土地 NFT
 * ============================================================ */
contract KingdomLand is ERC721, Ownable {
    using Strings for uint256;

    uint256 public constant SIZE = 20;            // 20 × 20 マス
    uint256 public constant TOTAL = SIZE * SIZE;  // 400 区画
    uint256 public landPrice = 0.001 ether;       // 1区画の価格 (テストネットETH)
    uint256 public totalMinted;

    event LandMinted(address indexed to, uint256 indexed landId, uint256 x, uint256 y);

    constructor() ERC721("Kingdom Land", "KLAND") Ownable(msg.sender) {}

    /// 座標 (x, y) の土地を購入する
    function mintLand(uint256 x, uint256 y) external payable returns (uint256 landId) {
        require(x < SIZE && y < SIZE, "out of map");
        require(msg.value >= landPrice, "not enough ETH");
        landId = y * SIZE + x;
        require(_ownerOf(landId) == address(0), "already owned");
        totalMinted++;
        _safeMint(msg.sender, landId);
        emit LandMinted(msg.sender, landId, x, y);
    }

    /// 全区画の所有者を一度に取得する (未所有は 0x0)。ゲーム画面の描画用
    function allOwners() external view returns (address[] memory owners) {
        owners = new address[](TOTAL);
        for (uint256 i = 0; i < TOTAL; i++) {
            owners[i] = _ownerOf(i);
        }
    }

    /// 地形 (0:草原 1:森 2:山 3:砂漠) — 座標から決定的に決まる
    function terrainOf(uint256 landId) public pure returns (uint8) {
        return uint8(uint256(keccak256(abi.encodePacked("terrain", landId))) % 4);
    }

    function tokenURI(uint256 landId) public view override returns (string memory) {
        _requireOwned(landId);
        string[4] memory names = ["Grassland", "Forest", "Mountain", "Desert"];
        uint256 x = landId % SIZE;
        uint256 y = landId / SIZE;
        string memory json = string.concat(
            '{"name":"Land (', x.toString(), ',', y.toString(), ')",',
            '"description":"A plot of land in Dragon Kingdom.",',
            '"attributes":[{"trait_type":"Terrain","value":"', names[terrainOf(landId)], '"},',
            '{"trait_type":"X","value":', x.toString(), '},',
            '{"trait_type":"Y","value":', y.toString(), '}]}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    // ---- 運営用 ----
    function setLandPrice(uint256 p) external onlyOwner { landPrice = p; }

    function withdraw() external onlyOwner {
        (bool ok, ) = payable(owner()).call{value: address(this).balance}("");
        require(ok, "withdraw failed");
    }
}

/* ============================================================
 *  ドラゴン NFT
 * ============================================================ */
contract KingdomDragon is ERC721, Ownable {
    using Strings for uint256;

    struct Dragon {
        uint8 element;      // 0:炎 1:氷 2:雷 3:闇
        uint16 power;       // 基礎パワー 50〜149
        uint16 level;       // 訓練で上がる
        uint32 landId;      // 配置中の土地
        uint64 lastTrained; // 最後に訓練した時刻
    }

    KingdomLand public immutable land;
    uint256 public dragonPrice = 0.002 ether;
    uint256 public constant TRAIN_COOLDOWN = 1 hours;
    Dragon[] public dragons;

    event DragonHatched(address indexed to, uint256 indexed dragonId, uint8 element, uint16 power);
    event DragonMoved(uint256 indexed dragonId, uint256 landId);
    event DragonTrained(uint256 indexed dragonId, uint16 level);

    constructor(address landContract) ERC721("Kingdom Dragon", "KDRGN") Ownable(msg.sender) {
        land = KingdomLand(landContract);
    }

    /// ドラゴンを孵化させる (自分の土地が必要)
    function hatch(uint256 landId) external payable returns (uint256 dragonId) {
        require(msg.value >= dragonPrice, "not enough ETH");
        require(land.ownerOf(landId) == msg.sender, "not your land");

        uint256 r = uint256(keccak256(abi.encodePacked(block.prevrandao, msg.sender, dragons.length)));
        dragonId = dragons.length;
        dragons.push(Dragon({
            element: uint8(r % 4),
            power: uint16(50 + (r >> 8) % 100),
            level: 1,
            landId: uint32(landId),
            lastTrained: 0
        }));
        _safeMint(msg.sender, dragonId);
        emit DragonHatched(msg.sender, dragonId, dragons[dragonId].element, dragons[dragonId].power);
    }

    /// 自分の別の土地へ移動する
    function moveTo(uint256 dragonId, uint256 landId) external {
        require(ownerOf(dragonId) == msg.sender, "not your dragon");
        require(land.ownerOf(landId) == msg.sender, "not your land");
        dragons[dragonId].landId = uint32(landId);
        emit DragonMoved(dragonId, landId);
    }

    /// 訓練 (1時間に1回、レベル+1)
    function train(uint256 dragonId) external {
        require(ownerOf(dragonId) == msg.sender, "not your dragon");
        Dragon storage d = dragons[dragonId];
        require(block.timestamp >= d.lastTrained + TRAIN_COOLDOWN, "dragon is resting");
        d.lastTrained = uint64(block.timestamp);
        d.level += 1;
        emit DragonTrained(dragonId, d.level);
    }

    function totalDragons() external view returns (uint256) { return dragons.length; }

    /// 全ドラゴンの情報をまとめて取得する (ゲーム画面の描画用)
    function allDragons() external view returns (address[] memory owners, Dragon[] memory list) {
        uint256 n = dragons.length;
        owners = new address[](n);
        list = new Dragon[](n);
        for (uint256 i = 0; i < n; i++) {
            owners[i] = _ownerOf(i);
            list[i] = dragons[i];
        }
    }

    function tokenURI(uint256 dragonId) public view override returns (string memory) {
        _requireOwned(dragonId);
        Dragon memory d = dragons[dragonId];
        string[4] memory el = ["Fire", "Ice", "Thunder", "Shadow"];
        string memory json = string.concat(
            '{"name":"Dragon #', dragonId.toString(), '",',
            '"description":"A dragon of Dragon Kingdom.",',
            '"attributes":[{"trait_type":"Element","value":"', el[d.element], '"},',
            '{"trait_type":"Power","value":', uint256(d.power).toString(), '},',
            '{"trait_type":"Level","value":', uint256(d.level).toString(), '}]}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    // ---- 運営用 ----
    function setDragonPrice(uint256 p) external onlyOwner { dragonPrice = p; }

    function withdraw() external onlyOwner {
        (bool ok, ) = payable(owner()).call{value: address(this).balance}("");
        require(ok, "withdraw failed");
    }
}
