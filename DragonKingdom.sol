// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
 * Dragon Kingdom — 4種類のNFT
 * ------------------------------------------------------------
 *  KingdomLand      土地     ERC-721  20×20=400区画。地形ごとに資材を生産
 *  KingdomResources 資材     ERC-1155 0:食料 1:木材 2:石材 3:金
 *  KingdomCastle    城       ERC-721  土地の上に建てる。レベルで生産量アップ
 *  KingdomDragon    ドラゴン ERC-721  自分の土地で孵化。食料で訓練
 *
 * デプロイ順（README参照）:
 *  1) KingdomLand(土地価格wei)
 *  2) KingdomResources(土地)
 *  3) KingdomCastle(土地, 資材)
 *  4) KingdomDragon(土地, 資材, 孵化価格wei, 相棒コレクション or 0x0)
 *     Polygon では相棒コレクション = League of Kingdoms Drago
 *     0x9e8ea82e76262e957d4cc24e04857a34b0d8f062（読み取りのみ）
 *  5) 資材.setCastle(城)  6) 資材.setGame(城, true)  7) 資材.setGame(ドラゴン, true)
 *
 * テストネット向けプロトタイプです。乱数は簡易的なもので、
 * 本番で販売する前に Chainlink VRF への置き換えと監査を行ってください。
 */

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";

/* ---------- メタデータ用の共通処理（OpenSea で画像付き表示） ---------- */
library KArt {
    function card(string memory bg, string memory accent, string memory title, string memory sub, string memory shape)
        internal pure returns (string memory)
    {
        string memory svg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 350 350">',
            '<rect width="350" height="350" fill="', bg, '"/>',
            '<g fill="', accent, '">', shape, '</g>',
            '<text x="175" y="292" font-family="serif" font-size="28" fill="#fff" text-anchor="middle">', title, '</text>',
            '<text x="175" y="322" font-family="sans-serif" font-size="16" fill="#fff" fill-opacity=".75" text-anchor="middle">', sub, '</text>',
            '</svg>'
        );
        return string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(svg)));
    }

    function json(string memory body) internal pure returns (string memory) {
        return string.concat("data:application/json;base64,", Base64.encode(bytes(body)));
    }
}

interface ICastleLevel {
    function levelOn(uint256 landId) external view returns (uint256);
}

/* ============================================================
 *  土地
 * ============================================================ */
contract KingdomLand is ERC721, Ownable {
    using Strings for uint256;

    uint256 public constant SIZE = 20;
    uint256 public constant TOTAL = SIZE * SIZE;
    uint256 public landPrice;
    uint256 public totalMinted;

    event LandMinted(address indexed to, uint256 indexed landId);

    /// price: 1区画の価格（wei）。Polygon なら POL、Base/Sepolia なら ETH 建て
    constructor(uint256 price) ERC721("Kingdom Land", "KLAND") Ownable(msg.sender) {
        landPrice = price;
    }

    function mintLand(uint256 x, uint256 y) external payable returns (uint256 landId) {
        require(x < SIZE && y < SIZE, "out of map");
        require(msg.value >= landPrice, "not enough ETH");
        landId = y * SIZE + x;
        require(_ownerOf(landId) == address(0), "already owned");
        totalMinted++;
        _safeMint(msg.sender, landId);
        emit LandMinted(msg.sender, landId);
    }

    function allOwners() external view returns (address[] memory owners) {
        owners = new address[](TOTAL);
        for (uint256 i = 0; i < TOTAL; i++) owners[i] = _ownerOf(i);
    }

    /// 地形 0:草原(食料) 1:森(木材) 2:山(石材) 3:砂漠(金)
    function terrainOf(uint256 landId) public pure returns (uint8) {
        return uint8(uint256(keccak256(abi.encodePacked("terrain", landId))) % 4);
    }

    function tokenURI(uint256 landId) public view override returns (string memory) {
        _requireOwned(landId);
        string[4] memory names = ["Grassland", "Forest", "Mountain", "Desert"];
        string[4] memory bgs = ["#4f7a3a", "#2f5530", "#5f5d6b", "#b28c48"];
        uint8 t = terrainOf(landId);
        string memory xy = string.concat("(", (landId % SIZE).toString(), ", ", (landId / SIZE).toString(), ")");
        string memory img = KArt.card(bgs[t], "#ffffff22", string.concat("Land ", xy), names[t],
            '<polygon points="175,50 300,120 175,190 50,120"/><polygon points="50,120 175,190 175,230 50,160" fill-opacity=".6"/><polygon points="300,120 175,190 175,230 300,160" fill-opacity=".4"/>');
        return KArt.json(string.concat(
            '{"name":"Land ', xy, '","description":"A plot of land in Dragon Kingdom. It produces resources every hour.",',
            '"image":"', img, '","attributes":[{"trait_type":"Terrain","value":"', names[t], '"},',
            '{"trait_type":"X","value":', (landId % SIZE).toString(), '},{"trait_type":"Y","value":', (landId / SIZE).toString(), '}]}'
        ));
    }

    function setLandPrice(uint256 p) external onlyOwner { landPrice = p; }

    function withdraw() external onlyOwner {
        (bool ok, ) = payable(owner()).call{value: address(this).balance}("");
        require(ok, "withdraw failed");
    }
}

/* ============================================================
 *  資材 (ERC-1155)  0:食料 1:木材 2:石材 3:金
 * ============================================================ */
contract KingdomResources is ERC1155, Ownable {
    using Strings for uint256;

    uint256 public constant MAX_STORE = 24 hours;   // 土地にたまる上限（24時間分）
    KingdomLand public immutable land;
    ICastleLevel public castle;
    mapping(address => bool) public isGame;         // 資材を消費・精算できるゲームコントラクト
    mapping(address => bool) public starterClaimed; // 初回ボーナス受取済み
    uint64[400] public lastHarvest;                 // 0 = まだ生産を始めていない

    event Harvested(address indexed player, uint256[] amounts);

    constructor(address landContract) ERC1155("") Ownable(msg.sender) {
        land = KingdomLand(landContract);
    }

    modifier onlyGame() { require(isGame[msg.sender], "not game"); _; }

    /// 1時間あたりの生産量。城レベル1ごとに +50%
    function ratePerHour(uint256 landId) public view returns (uint256) {
        uint256 base = land.terrainOf(landId) == 3 ? 20 : 100;
        uint256 lvl = address(castle) == address(0) ? 0 : castle.levelOn(landId);
        return base * (2 + lvl) / 2;
    }

    function pending(uint256 landId) public view returns (uint256) {
        uint256 t = lastHarvest[landId];
        if (t == 0) return 0;
        uint256 dt = block.timestamp - t;
        if (dt > MAX_STORE) dt = MAX_STORE;
        return ratePerHour(landId) * dt / 1 hours;
    }

    /// 自分の土地の資材をまとめて収穫（初回の土地はここで生産開始）
    function harvest(uint256[] calldata landIds) external {
        uint256[] memory ids = new uint256[](4);
        uint256[] memory amounts = new uint256[](4);
        for (uint256 i = 0; i < 4; i++) ids[i] = i;
        for (uint256 i = 0; i < landIds.length; i++) {
            uint256 id = landIds[i];
            require(land.ownerOf(id) == msg.sender, "not your land");
            amounts[land.terrainOf(id)] += pending(id);
            lastHarvest[id] = uint64(block.timestamp);
        }
        if (!starterClaimed[msg.sender]) {           // 初回ボーナス：城を1つ建てられる量
            starterClaimed[msg.sender] = true;
            amounts[0] += 1000; amounts[1] += 1000; amounts[2] += 1000; amounts[3] += 100;
        }
        _mintBatch(msg.sender, ids, amounts, "");
        emit Harvested(msg.sender, amounts);
    }

    /// 城レベルが変わる前に、その土地のたまった資材を精算する
    function settle(uint256 landId, address to) external onlyGame {
        uint256 p = pending(landId);
        lastHarvest[landId] = uint64(block.timestamp);
        if (p > 0) _mint(to, land.terrainOf(landId), p, "");
    }

    /// 資材を消費（城の建設、ドラゴンの孵化・訓練）
    function spend(address from, uint256[4] memory cost) external onlyGame {
        uint256[] memory ids = new uint256[](4);
        uint256[] memory amounts = new uint256[](4);
        for (uint256 i = 0; i < 4; i++) { ids[i] = i; amounts[i] = cost[i]; }
        _burnBatch(from, ids, amounts);
    }

    function allLastHarvest() external view returns (uint64[400] memory) { return lastHarvest; }

    function uri(uint256 id) public pure override returns (string memory) {
        require(id < 4, "unknown resource");
        string[4] memory names = ["Food", "Wood", "Stone", "Gold"];
        string[4] memory bgs = ["#6b8f3e", "#6a4a2c", "#5b5e70", "#8a6a1e"];
        string[4] memory fg = ["#e9f1c8", "#d9b98a", "#d6d8e2", "#ffd76a"];
        string memory img = KArt.card(bgs[id], fg[id], names[id], "Dragon Kingdom resource",
            '<circle cx="175" cy="140" r="80"/>');
        return KArt.json(string.concat(
            '{"name":"', names[id], '","description":"A resource of Dragon Kingdom, used to build castles and raise dragons.",',
            '"image":"', img, '"}'
        ));
    }

    // ---- 運営用 ----
    function setCastle(address c) external onlyOwner { castle = ICastleLevel(c); }
    function setGame(address g, bool on) external onlyOwner { isGame[g] = on; }
}

/* ============================================================
 *  城  (tokenId = 土地のID。1区画に1つ)
 * ============================================================ */
contract KingdomCastle is ERC721, Ownable, ICastleLevel {
    using Strings for uint256;

    uint8 public constant MAX_LEVEL = 10;
    KingdomLand public immutable land;
    KingdomResources public immutable res;
    mapping(uint256 => uint8) public level;

    event CastleBuilt(address indexed owner, uint256 indexed landId);
    event CastleUpgraded(uint256 indexed landId, uint8 level);

    constructor(address landContract, address resContract) ERC721("Kingdom Castle", "KCSTL") Ownable(msg.sender) {
        land = KingdomLand(landContract);
        res = KingdomResources(resContract);
    }

    function buildCost() public pure returns (uint256[4] memory) { return [uint256(0), 500, 500, 0]; }

    /// 現在のレベルから次へ上げる費用
    function upgradeCost(uint8 current) public pure returns (uint256[4] memory c) {
        c[0] = 300 * uint256(current);
        c[1] = 600 * uint256(current);
        c[2] = 600 * uint256(current);
        c[3] = 50 * uint256(current);
    }

    function build(uint256 landId) external {
        require(land.ownerOf(landId) == msg.sender, "not your land");
        require(_ownerOf(landId) == address(0), "castle exists");
        res.settle(landId, msg.sender);
        res.spend(msg.sender, buildCost());
        level[landId] = 1;
        _safeMint(msg.sender, landId);
        emit CastleBuilt(msg.sender, landId);
    }

    function upgrade(uint256 landId) external {
        require(ownerOf(landId) == msg.sender, "not your castle");
        require(land.ownerOf(landId) == msg.sender, "not your land");
        uint8 cur = level[landId];
        require(cur < MAX_LEVEL, "max level");
        res.settle(landId, msg.sender);
        res.spend(msg.sender, upgradeCost(cur));
        level[landId] = cur + 1;
        emit CastleUpgraded(landId, cur + 1);
    }

    /// 生産に効くレベル（城と土地の持ち主が同じときだけ）
    function levelOn(uint256 landId) external view returns (uint256) {
        address o = _ownerOf(landId);
        if (o == address(0) || o != land.ownerOf(landId)) return 0;
        return level[landId];
    }

    function allLevels() external view returns (uint8[400] memory out) {
        for (uint256 i = 0; i < 400; i++) out[i] = level[i];
    }

    function tokenURI(uint256 landId) public view override returns (string memory) {
        _requireOwned(landId);
        string memory lv = uint256(level[landId]).toString();
        string memory img = KArt.card("#2b3456", "#e3b04b", string.concat("Castle Lv ", lv),
            string.concat("on Land #", landId.toString()),
            '<rect x="115" y="110" width="120" height="110"/><rect x="85" y="80" width="40" height="140"/><rect x="225" y="80" width="40" height="140"/><polygon points="160,60 175,30 190,60"/><rect x="160" y="60" width="30" height="50"/>');
        return KArt.json(string.concat(
            '{"name":"Castle #', landId.toString(), '","description":"A castle in Dragon Kingdom. Higher levels boost land production.",',
            '"image":"', img, '","attributes":[{"trait_type":"Level","value":', lv, '},',
            '{"trait_type":"Land","value":', landId.toString(), '}]}'
        ));
    }
}

/* ============================================================
 *  ドラゴン
 * ============================================================ */
contract KingdomDragon is ERC721, Ownable {
    using Strings for uint256;

    struct Dragon {
        uint8 element;      // 0:炎 1:氷 2:雷 3:闇
        uint16 power;       // 50〜149（相棒は100〜149）
        uint16 level;
        uint32 landId;
        uint64 lastTrained;
        bool partner;       // 外部コレクションの保有者が受け取った相棒ドラゴン
    }

    KingdomLand public immutable land;
    KingdomResources public immutable res;
    /// 相棒ドラゴンを受け取れる外部NFTコレクション（読み取りのみ。0x0 なら無効）
    IERC721 public immutable partnerCollection;
    uint256 public dragonPrice;
    uint256 public constant HATCH_FOOD = 300;
    uint256 public constant TRAIN_FOOD_PER_LEVEL = 100;
    uint256 public constant TRAIN_COOLDOWN = 1 hours;
    uint16 public constant PARTNER_START_LEVEL = 5;
    Dragon[] public dragons;
    mapping(uint256 => bool) public partnerClaimed;      // 外部NFTのトークンID → 受取済み
    mapping(uint256 => uint256) public partnerSource;    // ドラゴンID → 外部NFTのトークンID

    event DragonHatched(address indexed to, uint256 indexed dragonId, uint8 element, uint16 power);
    event PartnerClaimed(address indexed to, uint256 indexed dragonId, uint256 indexed partnerTokenId);
    event DragonMoved(uint256 indexed dragonId, uint256 landId);
    event DragonTrained(uint256 indexed dragonId, uint16 level);

    constructor(address landContract, address resContract, uint256 price, address partner)
        ERC721("Kingdom Dragon", "KDRGN") Ownable(msg.sender)
    {
        land = KingdomLand(landContract);
        res = KingdomResources(resContract);
        dragonPrice = price;
        partnerCollection = IERC721(partner);
    }

    function _newDragon(address to, uint256 landId, uint256 minPower, uint16 lvl, bool partner) internal returns (uint256 dragonId) {
        uint256 r = uint256(keccak256(abi.encodePacked(block.prevrandao, to, dragons.length)));
        dragonId = dragons.length;
        dragons.push(Dragon(uint8(r % 4), uint16(minPower + (r >> 8) % (150 - minPower)), lvl, uint32(landId), 0, partner));
        _safeMint(to, dragonId);
        emit DragonHatched(to, dragonId, dragons[dragonId].element, dragons[dragonId].power);
    }

    /// 孵化：ネイティブ通貨 + 食料300。自分の土地が必要
    function hatch(uint256 landId) external payable returns (uint256) {
        require(msg.value >= dragonPrice, "not enough ETH");
        require(land.ownerOf(landId) == msg.sender, "not your land");
        res.spend(msg.sender, [HATCH_FOOD, 0, 0, 0]);
        return _newDragon(msg.sender, landId, 50, 1, false);
    }

    /// 相棒ドラゴンを受け取る：外部NFTを持っていれば無料（1トークンにつき1回）。
    /// 外部NFTは ownerOf で確認するだけで、移動・ロック・変更はしない。
    function claimPartner(uint256 partnerTokenId, uint256 landId) external returns (uint256 dragonId) {
        require(address(partnerCollection) != address(0), "partner disabled");
        require(partnerCollection.ownerOf(partnerTokenId) == msg.sender, "not partner holder");
        require(!partnerClaimed[partnerTokenId], "partner already claimed");
        require(land.ownerOf(landId) == msg.sender, "not your land");
        partnerClaimed[partnerTokenId] = true;
        dragonId = _newDragon(msg.sender, landId, 100, PARTNER_START_LEVEL, true);
        partnerSource[dragonId] = partnerTokenId;
        emit PartnerClaimed(msg.sender, dragonId, partnerTokenId);
    }

    function moveTo(uint256 dragonId, uint256 landId) external {
        require(ownerOf(dragonId) == msg.sender, "not your dragon");
        require(land.ownerOf(landId) == msg.sender, "not your land");
        dragons[dragonId].landId = uint32(landId);
        emit DragonMoved(dragonId, landId);
    }

    /// 訓練：食料（100×現在レベル）を消費、1時間に1回
    function train(uint256 dragonId) external {
        require(ownerOf(dragonId) == msg.sender, "not your dragon");
        Dragon storage d = dragons[dragonId];
        require(block.timestamp >= d.lastTrained + TRAIN_COOLDOWN, "dragon is resting");
        res.spend(msg.sender, [TRAIN_FOOD_PER_LEVEL * d.level, 0, 0, 0]);
        d.lastTrained = uint64(block.timestamp);
        d.level += 1;
        emit DragonTrained(dragonId, d.level);
    }

    function allDragons() external view returns (address[] memory owners, Dragon[] memory list) {
        uint256 n = dragons.length;
        owners = new address[](n);
        list = new Dragon[](n);
        for (uint256 i = 0; i < n; i++) { owners[i] = _ownerOf(i); list[i] = dragons[i]; }
    }

    function tokenURI(uint256 dragonId) public view override returns (string memory) {
        _requireOwned(dragonId);
        Dragon memory d = dragons[dragonId];
        string[4] memory el = ["Fire", "Ice", "Thunder", "Shadow"];
        string[4] memory col = ["#ee6a3a", "#86d6f2", "#f3d143", "#9a73d4"];
        string memory img = KArt.card("#1b2140", col[d.element], string.concat("Dragon #", dragonId.toString()),
            string.concat(el[d.element], " / Lv ", uint256(d.level).toString(), " / Power ", uint256(d.power).toString()),
            '<ellipse cx="175" cy="150" rx="60" ry="38"/><circle cx="240" cy="110" r="26"/><polygon points="160,130 60,50 120,140"/><polygon points="190,130 290,40 230,140"/><polygon points="115,160 40,200 120,175"/>');
        return KArt.json(string.concat(
            '{"name":"Dragon #', dragonId.toString(), '","description":"A dragon of Dragon Kingdom.",',
            '"image":"', img, '","attributes":[{"trait_type":"Element","value":"', el[d.element], '"},',
            '{"trait_type":"Power","value":', uint256(d.power).toString(), '},',
            '{"trait_type":"Level","value":', uint256(d.level).toString(), '},',
            '{"trait_type":"Partner","value":"', d.partner ? "Yes" : "No", '"}]}'
        ));
    }

    function setDragonPrice(uint256 p) external onlyOwner { dragonPrice = p; }

    function withdraw() external onlyOwner {
        (bool ok, ) = payable(owner()).call{value: address(this).balance}("");
        require(ok, "withdraw failed");
    }
}
