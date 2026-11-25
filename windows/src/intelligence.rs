use crate::engines::{clean_tracking_url, to_chinese_uppercase_rmb};
use crate::model::{now_unix_secs, ClipContentType};

// ============================================================================
// 1. 百分号编码中文 URL 可读解码与社媒分享口令剥壳提链
// ============================================================================

/// O(1) 前置 `%` 门控解码：将含 `%E4%B8%AD...` 的 URL 解码为可读中文预览，不破坏底层原始 URL
pub fn decode_percent_readable_url(raw: &str) -> String {
    if raw.len() > 4_096 || !raw.contains('%') || !raw.contains("://") {
        return raw.to_string();
    }
    let bytes = raw.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(hi), Some(lo)) = (hex_val(bytes[i + 1]), hex_val(bytes[i + 2])) {
                out.push((hi << 4) | lo);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    match String::from_utf8(out) {
        Ok(decoded) if !decoded.is_empty() => decoded.replace(['\r', '\n'], " ").replace('\0', ""),
        _ => raw.to_string(),
    }
}

fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

/// 从小红书 / B站 / 抖音 / 飞书等混排分享口令中剥壳提纯首个干净网页 URL（网盘含提取码时保留不盲剥）
pub fn extract_clean_share_url(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    let lower = trimmed.to_lowercase();
    let start = lower.find("https://").or_else(|| lower.find("http://"))?;
    let tail = &trimmed[start..];

    let mut end_byte = 0;
    let mut open_parens = 0i32;
    let mut open_brackets = 0i32;

    for (idx, ch) in tail.char_indices() {
        if ch.is_whitespace() || ch.is_control() {
            break;
        }
        // 遇到中日韩汉字、全角标点或口令粘连引号立即截断（保留拉丁扩展/西里尔/希腊供防钓鱼引擎识别拦截）
        let cv = ch as u32;
        if (0x2E80..=0x9FFF).contains(&cv)
            || (0xF900..=0xFAFF).contains(&cv)
            || (0xFE30..=0xFFEF).contains(&cv)
        {
            break;
        }
        // 遇到中文标点或口令粘连引号立即截断
        if matches!(
            ch,
            '，' | '。'
                | '！'
                | '？'
                | '；'
                | '：'
                | '、'
                | '「'
                | '」'
                | '『'
                | '』'
                | '【'
                | '】'
                | '《'
                | '》'
                | '（'
                | '）'
                | '"'
                | '\''
                | '<'
                | '>'
        ) {
            break;
        }
        if ch == '(' {
            open_parens += 1;
        } else if ch == ')' {
            if open_parens <= 0 {
                break;
            }
            open_parens -= 1;
        } else if ch == '[' {
            open_brackets += 1;
        } else if ch == ']' {
            if open_brackets <= 0 {
                break;
            }
            open_brackets -= 1;
        }
        end_byte = idx + ch.len_utf8();
    }

    if end_byte == 0 {
        return None;
    }

    let mut candidate = tail[..end_byte]
        .trim_end_matches(['.', ',', ';', ':', '!', '?'])
        .to_string();
    let host_check = candidate
        .strip_prefix("https://")
        .or_else(|| candidate.strip_prefix("http://"))
        .unwrap_or("");
    let host = host_check.split(['/', '?', '#']).next().unwrap_or("");
    if !(host.contains('.')
        || host.eq_ignore_ascii_case("localhost")
        || host.starts_with("localhost:"))
    {
        return None;
    }

    if let Some(cleaned) = clean_tracking_url(&candidate) {
        candidate = cleaned;
    }
    Some(candidate)
}

// ============================================================================
// 2. 跨语言应用/模态同义词、拼音首字母与情景时间窗盲搜
// ============================================================================

const APP_SYNONYM_GROUPS: &[&[&str]] = &[
    &[
        "code",
        "vscode",
        "visual studio code",
        "cursor",
        "antigravity",
        "windsurf",
        "zed",
        "ide",
        "编辑器",
    ],
    &["wechat", "weixin", "wx", "微信", "聊天"],
    &["feishu", "lark", "飞书"],
    &["dingtalk", "钉钉"],
    &["qq", "tim", "腾讯qq"],
    &[
        "windowsterminal",
        "wt",
        "cmd",
        "powershell",
        "pwsh",
        "iterm",
        "iterm2",
        "ghostty",
        "warp",
        "alacritty",
        "terminal",
        "终端",
        "命令行",
        "shell",
    ],
    &[
        "chrome",
        "google chrome",
        "msedge",
        "edge",
        "firefox",
        "safari",
        "arc",
        "brave",
        "browser",
        "浏览器",
    ],
    &["excel", "wps", "numbers", "表格", "电子表格"],
    &[
        "winword", "word", "notion", "obsidian", "typora", "文档", "笔记",
    ],
];

pub fn matches_app_or_modality_synonym(
    token_lower: &str,
    source_app: Option<&str>,
    kind: ClipContentType,
) -> bool {
    let modality_hit = match kind {
        ClipContentType::Image => matches!(
            token_lower,
            "图片" | "截图" | "相册" | "image" | "img" | "pic" | "photo" | "screenshot"
        ),
        ClipContentType::Link => matches!(
            token_lower,
            "链接" | "网址" | "网页" | "link" | "url" | "http"
        ),
        ClipContentType::File => matches!(
            token_lower,
            "文件" | "附件" | "目录" | "文件夹" | "file" | "folder"
        ),
        ClipContentType::Text => matches!(token_lower, "文本" | "文字" | "text"),
    };
    if modality_hit {
        return true;
    }

    let Some(app_raw) = source_app else {
        return false;
    };
    let app_trimmed = app_raw.trim();
    if app_trimmed.is_empty() {
        return false;
    }

    for group in APP_SYNONYM_GROUPS {
        if group.contains(&token_lower) {
            let app_lower = app_trimmed.to_lowercase();
            if group
                .iter()
                .any(|alias| app_lower == *alias || (alias.len() >= 4 && app_lower.contains(alias)))
            {
                return true;
            }
        }
    }
    false
}

/// 识别 IDE / 代码编辑器 / 终端来源应用（过滤其默认附带的语法着色 HTML，避免误扰）
pub fn is_code_editor_or_terminal_app(source_app: Option<&str>) -> bool {
    let Some(app) = source_app else {
        return false;
    };
    let lower = app.trim().to_lowercase();
    if lower.is_empty() {
        return false;
    }
    if matches!(
        lower.as_str(),
        "code" | "wt" | "cmd" | "vim" | "nvim" | "emacs"
    ) {
        return true;
    }
    const IDE_KEYS: &[&str] = &[
        "antigravity",
        "cursor",
        "vscode",
        "visual studio",
        "windsurf",
        "trae",
        "zed",
        "idea",
        "intellij",
        "pycharm",
        "webstorm",
        "goland",
        "clion",
        "rustrover",
        "rider",
        "sublime",
        "notepad++",
        "windowsterminal",
        "powershell",
        "pwsh",
        "terminal",
        "iterm",
        "ghostty",
        "warp",
        "alacritty",
        "wezterm",
        "git-bash",
        "mintty",
    ];
    IDE_KEYS.iter().any(|k| lower.contains(k))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TimeScopeFilter {
    Recent15Min,
    Today,
    Yesterday,
    ThisWeek,
}

impl TimeScopeFilter {
    pub fn from_token(token: &str) -> Option<Self> {
        match token.to_lowercase().as_str() {
            "刚才" | "刚刚" | "recent" => Some(Self::Recent15Min),
            "今天" | "今日" | "today" => Some(Self::Today),
            "昨天" | "昨日" | "yesterday" => Some(Self::Yesterday),
            "本周" | "这周" | "七天" | "7d" | "week" => Some(Self::ThisWeek),
            _ => None,
        }
    }

    pub fn matches_timestamp(self, item_secs: u64, now_secs: u64) -> bool {
        let age = now_secs.saturating_sub(item_secs);
        match self {
            Self::Recent15Min => age <= 900,
            Self::Today => age <= 86_400,
            Self::Yesterday => (43_200..=172_800).contains(&age),
            Self::ThisWeek => age <= 7 * 86_400,
        }
    }
}

/// 轻量零依赖汉字拼音首字母提取（覆盖高频办公/开发/商务常用汉字 + ASCII 字母数字，支持如 `fptt` 命中「发票抬头」）
pub fn extract_pinyin_initials(text: &str, max_chars: usize) -> String {
    let mut out = String::with_capacity(text.len().min(max_chars));
    for ch in text.chars().take(max_chars) {
        if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
        } else if let Some(initial) = chinese_char_initial(ch) {
            out.push(initial);
        }
    }
    out
}

pub fn is_pure_ascii_letters(s: &str) -> bool {
    s.len() >= 2 && s.bytes().all(|b| b.is_ascii_alphabetic())
}

fn chinese_char_initial(ch: char) -> Option<char> {
    if !('\u{4E00}'..='\u{9FA5}').contains(&ch) {
        return None;
    }
    static PINYIN_LUT: std::sync::OnceLock<Box<[u8; 20_902]>> = std::sync::OnceLock::new();
    let lut = PINYIN_LUT.get_or_init(|| {
        const INITIAL_GROUPS: &[(u8, &str)] = &[
            (b'a', "阿啊哎哀埃挨癌矮艾爱碍安氨俺岸按案暗昂凹熬傲奥澳"),
            (b'b', "八巴拔把坝爸罢白百柏摆败拜班般颁斑搬板版办半伴扮瓣帮绑榜膀傍包胞宝饱保堡报抱豹暴爆杯悲碑北贝备背倍被奔本笨崩逼鼻比鄙笔币必毕闭辟碧壁避臂边编鞭扁便变遍辨辩标彪表憋别宾滨冰兵丙柄饼并病拨波玻剥播脖伯驳泊捕补不布步簿部"),
            (b'c', "擦猜才材财裁采彩踩菜参餐残蚕惨灿仓苍舱藏操糙槽草册侧测策层叉插查茶察差拆柴搀掺蝉馋缠产铲阐颤昌长肠尝偿常厂场畅倡唱抄钞超巢朝嘲潮吵炒车扯彻撤尘臣辰陈衬称撑成呈承诚城乘惩程澄橙吃痴池驰迟持尺齿耻斥赤翅充冲虫崇抽仇绸愁稠筹酬丑臭出初除厨础储楚处触川穿传船喘串疮窗床闯创吹炊锤春纯唇醇蠢戳词祠雌此次刺从匆葱聪丛凑粗促醋簇窜篡催摧脆粹翠村存寸磋撮挫措错"),
            (b'd', "搭达答打大呆歹代带待怠殆贷袋逮戴丹单担耽胆旦但诞弹淡蛋氮当挡党荡刀导岛倒蹈到悼道稻得德的灯登等瞪凳低堤滴迪敌涤笛底抵地弟帝递第颠典点碘电店垫淀殿刁叼雕吊钓调掉爹跌叠碟蝶丁叮盯钉顶鼎订定丢东冬懂动冻栋洞兜抖陡豆逗督毒读独堵赌睹妒度渡端短段断缎堆队对吨敦蹲盾顿多夺朵躲剁堕舵惰跺"),
            (b'f', "发乏伐罚阀筏法帆番翻凡烦繁反返犯泛饭范贩方坊芳防妨房肪仿访纺放飞非啡菲肥匪诽吠废沸肺费分吩纷芬坟焚粉份奋愤粪丰风枫封疯峰锋蜂逢缝讽凤奉佛否夫肤孵敷弗伏扶拂服俘浮符幅福抚府斧俯釜辅腐父付妇负附咐阜复赴副傅富赋腹覆"),
            (b'g', "该改钙盖溉干甘杆肝柑竿秆赶敢感赣冈刚钢缸纲岗港杠高膏糕搞稿告哥歌搁割革葛格阁隔个各给根跟耕更庚羹埂耿梗工弓公功攻供宫恭躬巩汞拱共贡勾沟钩狗苟构购够辜菇咕箍估沽孤姑鼓古骨谷股故顾固雇刮瓜剐寡挂褂乖拐怪棺关官冠观管馆罐惯灌贯光广逛归圭龟规闺硅瑰轨诡癸鬼柜贵桂跪辊滚棍锅郭国果裹过"),
            (b'h', "哈骸海亥骇害氦酣憨含函寒韩罕喊汉汗旱悍焊瀚航杭豪嚎壕好号浩耗呵喝荷核禾何合盒貉阂河涸赫褐鹤黑嘿痕很狠恨哼恒横衡轰哄烘虹鸿洪宏弘红喉侯猴吼厚候后呼乎忽瑚壶葫胡蝴狐糊湖弧虎唬护互沪户花哗华猾滑画划化话槐徊怀淮坏欢环桓还缓换患唤痪豢焕涣宦幻荒慌皇凰黄磺蝗簧恍晃谎灰挥辉徽恢蛔回毁悔慧卉惠晦贿秽会烩汇讳诲绘荤昏婚魂浑混豁活伙火获或惑霍货祸"),
            (b'j', "击圾基机畸稽积箕肌饥迹激讥鸡姬绩缉吉极棘辑籍集及急疾汲即嫉级挤几脊己蓟技冀季伎祭剂悸济寄寂计记既忌际妓继纪嘉枷夹佳家加荚颊贾甲钾假稼价架驾嫁歼监坚尖笺间煎兼肩艰奸缄茧检柬碱硷拣捡简俭剪减荐槛鉴践贱见键箭件健舰剑饯渐溅涧建僵姜将浆江疆蒋桨奖讲匠酱降蕉椒礁焦胶交郊浇骄娇嚼搅铰矫侥脚狡角饺缴绞剿教酵轿较叫窖揭接皆秸街阶截劫节桔杰捷睫竭洁结解姐戒藉芥界借介疥诫届巾筋斤金今津襟紧锦仅谨进靳晋禁近烬浸尽劲荆兢茎睛晶鲸京惊精粳经井警景颈静境敬镜径痉靖竟竞净炯窘揪究纠玖韭久灸九酒厩救旧臼舅咎就疚鞠拘狙疽居驹菊局咀矩举沮聚拒据巨具距踞锯俱句惧炬剧捐鹃娟倦眷卷绢撅攫抉掘倔爵觉决诀绝均菌钧军君峻俊竣浚郡骏"),
            (b'k', "咔咖卡咯开揩楷凯慨刊堪勘坎砍看康慷糠扛抗亢炕考拷烤靠坷苛柯棵磕颗科壳咳可渴克刻客课肯啃垦恳坑吭空恐孔控抠口扣寇枯哭窟苦酷库裤夸垮挎跨胯块筷侩快宽款匡筐狂框矿眶旷况亏盔岿窥葵奎魁傀馈愧溃坤昆捆困括扩廓阔"),
            (b'l', "垃拉喇蜡腊辣啦莱来赖蓝婪栏拦篮阑兰澜谰揽览懒缆烂滥琅榔狼廊郎朗浪捞劳牢老佬姥酪烙涝勒乐雷镭蕾磊累儡垒擂肋类泪棱楞冷厘梨犁黎篱狸离漓理李里鲤礼莉荔吏栗丽厉励砾历利傈例俐痢立粒沥隶力璃哩俩联莲连镰廉怜涟帘敛脸链恋炼练粮凉梁粱良两辆量晾亮谅撩聊僚疗燎寥辽潦了撂镣廖料列裂烈劣猎琳林磷霖临邻鳞淋凛赁吝拎玲菱零龄铃伶羚凌灵陵岭领另令溜琉榴硫馏留刘瘤流柳六龙聋咙笼窿隆垄拢陇楼娄搂篓漏陋芦卢颅庐炉掳卤虏鲁麓碌露路赂鹿潞禄录陆戮驴吕铝侣旅履屡缕虑氯律率滤绿峦挛孪滦卵乱掠略抡轮伦仑沦纶论萝螺罗逻锣箩骡裸落洛骆络"),
            (b'm', "妈麻玛码蚂马骂嘛吗埋买麦卖迈脉瞒馒蛮满蔓曼慢漫谩芒茫盲氓忙莽猫茅锚毛矛铆卯茂冒帽貌贸么玫枚梅酶霉煤没眉媒镁每美昧寐妹媚门闷们萌蒙檬盟锰猛梦孟眯醚靡迷谜弥米秘觅泌蜜密幂棉眠绵冕免勉娩缅面苗描瞄藐秒渺庙妙蔑灭民抿皿敏悯闽明螟鸣铭名命谬摸摹蘑模膜磨摩魔抹末莫墨默沫漠寞陌谋牟某母亩牡姆拇木目睦牧穆"),
            (b'n', "拿哪呐钠那娜纳氖乃奶耐奈南男难囊挠脑恼闹淖呢馁内嫩能妮霓倪泥尼拟你匿腻逆溺蔫拈年碾撵捻念娘酿鸟尿捏聂孽啮镊镍涅您柠狞凝宁拧泞牛扭钮纽脓浓农弄奴努怒女暖虐疟挪懦糯诺"),
            (b'o', "哦欧鸥殴藕呕偶沤"),
            (b'p', "啪趴爬帕怕琶拍排牌徘湃派攀潘盘磐盼畔判叛乓庞旁耪胖抛咆刨炮袍跑泡呸胚培裴赔陪配佩沛喷盆砰抨烹澎彭蓬棚硼篷膨朋鹏捧碰坯砒霹批披劈琵毗啤脾疲皮匹痞僻屁譬篇偏片骗飘漂瓢票撇瞥拼频贫品聘乒坪苹萍平凭瓶评屏坡泼颇婆破魄迫粕剖扑铺仆莆葡菩蒲埔朴圃普浦谱曝瀑"),
            (b'q', "期欺栖戚妻七凄漆柒沏其棋奇歧畦崎脐齐旗祈祁骑起岂乞企启契砌器气迄弃汽泣讫掐恰洽牵扦钎铅千迁签仟谦乾黔钱钳前潜遣浅谴堑嵌欠歉枪呛腔羌墙蔷强抢橇锹敲悄桥瞧乔侨巧鞘撬翘峭俏窍切茄且怯窃钦侵亲秦琴勤芹擒禽寝沁青轻氢倾卿清擎晴氰情顷请庆琼穷秋丘邱球求囚酋泅趋区蛆曲躯屈驱渠取娶龋趣去圈颧权醛泉全痊拳犬券劝缺炔瘸却鹊榷确雀裙群"),
            (b'r', "然燃冉染瓤壤攘嚷让饶扰绕惹热壬仁人忍韧任认刃妊纫扔仍日戎茸蓉荣融熔溶容绒冗揉柔肉茹蠕儒孺如辱乳汝入褥软阮蕊瑞锐闰润若弱"),
            (b's', "撒洒萨腮鳃塞赛三叁伞散桑嗓丧搔骚扫嫂瑟色涩森僧莎砂杀刹沙纱傻啥煞筛晒珊苫杉山删煽衫闪陕擅赡膳善汕扇缮墒伤商赏晌上尚裳梢捎稍烧芍勺韶少哨邵绍奢赊蛇舌舍赦摄射慑涉社设砷申呻伸身深娠绅神沈审婶甚肾慎渗声生甥牲升绳省盛剩胜圣师失狮施湿诗尸虱十石拾时什食蚀实识史矢使屎驶始式示士世柿事拭誓逝势是嗜噬适仕侍释饰氏市恃室视试收手首守寿授售受瘦兽蔬枢梳殊抒输叔舒淑疏书赎孰熟薯暑曙署蜀黍鼠属术述树束戍竖墅庶数漱恕刷耍摔衰甩帅栓拴霜双爽谁水睡税吮瞬顺舜说硕朔烁斯撕嘶思私司丝死肆寺嗣四伺似饲巳松耸怂颂送宋讼诵搜艘擞嗽苏酥俗素速粟僳塑溯宿诉肃酸蒜算虽隋随绥髓碎岁穗遂隧祟孙损笋蓑梭唆缩琐索锁所"),
            (b't', "塌他它她塔獭挞蹋踏胎苔抬台泰酞太态汰坍摊贪瘫滩坛檀痰潭谭谈坦毯袒碳探叹炭汤塘搪堂棠膛唐糖倘躺淌趟烫掏涛滔绦萄桃逃淘陶讨套特藤腾疼誊梯剔踢锑提题蹄啼体替嚏惕涕剃屉天添填田甜恬舔腆挑条迢眺跳贴铁帖厅听烃汀廷停亭庭挺艇通桐酮瞳同铜彤童桶捅统痛偷投头透凸秃突图徒途涂屠土吐兔湍团推颓腿蜕褪退吞屯臀拖托脱鸵陀驮驼椭妥拓唾"),
            (b'w', "挖哇蛙洼娃瓦袜歪外豌弯湾玩顽丸烷完碗挽晚皖惋宛婉万腕汪王亡枉网往旺望忘妄威巍微危韦违桅围唯惟为潍维苇萎委伟伪尾纬未蔚味畏胃喂魏位渭谓尉慰卫瘟温蚊文闻纹吻稳紊问嗡翁瓮挝蜗涡窝我斡卧握沃巫呜钨乌污诬屋无芜梧吾吴毋武五捂午舞伍侮坞戊雾晤物勿务悟误"),
            (b'x', "昔熙析西硒矽晰嘻吸锡牺稀息希悉膝夕惜熄烯溪汐犀檄袭席习媳喜铣洗系隙戏细瞎虾匣霞辖暇峡侠狭下厦夏吓掀锨先仙鲜纤咸贤衔舷闲涎弦嫌显险现献县腺馅羡宪陷限线相厢镶香箱襄湘乡翔祥详想响享项巷橡像向象萧硝霄削哮嚣销消宵淆晓小孝校肖啸笑效楔些歇蝎鞋协挟携邪斜胁谐写械卸蟹懈泄泻谢屑薪芯锌欣辛新忻心信衅星腥猩惺兴刑型形邢行醒幸杏性姓兄凶胸匈汹雄熊休修羞朽嗅锈秀袖绣墟戌需虚嘘须徐许蓄酗叙旭序畜恤絮婿绪续轩喧宣悬旋玄选癣眩绚靴薛学穴雪血勋熏循旬询寻驯巡殉汛训讯逊迅"),
            (b'y', "压押鸦鸭呀丫芽牙蚜崖衙涯雅哑亚讶焉咽阉烟淹盐严研蜒岩延言颜阎炎沿奄掩眼衍演艳堰燕厌砚雁唁彦焰宴谚验殃央鸯秧杨扬佯疡羊洋阳氧仰痒养样漾邀腰妖瑶摇尧遥窑谣姚咬舀药要耀椰噎耶爷野冶也页掖业叶曳腋夜液一壹医揖铱依伊衣颐夷遗移仪胰疑沂宜姨彝椅蚁倚已乙矣以艺抑易邑屹亿役臆逸肄疫亦裔意毅忆义益溢诣议谊译异翼翌绎茵荫因殷音阴姻吟银淫寅饮尹引隐印英樱婴鹰应缨莹萤营荧蝇迎赢盈影颖硬映哟拥佣臃痈庸雍踊蛹咏泳涌永恿勇用幽优悠忧尤由邮铀犹油游酉有友右佑釉诱又幼迂淤于盂榆虞愚舆余俞逾鱼愉渝渔隅予娱雨与屿禹宇语羽玉域芋郁吁遇喻峪御愈欲狱育誉浴寓裕预豫驭鸳渊冤元垣袁原援辕园员圆猿源缘远苑愿怨院曰约越跃钥岳粤月悦阅耘云郧匀陨允运蕴酝晕韵孕"),
            (b'z', "匝砸杂栽哉灾宰载再在咱攒暂赞赃脏葬遭糟凿藻枣早澡蚤躁噪造皂灶燥责择则泽贼怎增憎曾赠扎喳渣札轧铡闸眨栅榨咋乍炸诈摘斋宅窄债寨瞻毡詹粘沾盏斩辗崭展蘸栈占战站湛绽樟章彰漳张掌涨杖丈帐账仗胀瘴障招昭找沼赵照罩兆肇召遮折哲蛰辙者锗蔗这浙珍斟真甄砧臻贞针侦枕疹诊震振镇阵蒸挣睁征狰争怔整拯正政帧症郑证芝枝支吱蜘知肢脂汁之织职直植殖执值侄址指止趾只旨纸志挚掷至致置帜峙制智秩稚质炙痔滞治窒中盅忠钟衷终种肿重仲众舟周州洲诌粥轴肘帚咒皱宙昼骤珠株蛛朱猪诸诛逐竹烛煮拄瞩嘱主著柱助蛀贮铸筑住注祝驻抓爪拽专砖转撰赚篆桩庄装妆撞壮状椎锥追赘坠缀谆准捉拙卓桌琢茁酌啄着灼浊兹咨资姿滋淄孜紫仔籽滓子自渍字鬃棕踪宗综总纵邹走奏揍租足卒族祖诅阻组钻纂嘴醉最罪尊遵昨左佐柞做作坐座"),
        ];
        let mut table = Box::new([0u8; 20_902]);
        for (initial, chars) in INITIAL_GROUPS {
            for c in chars.chars() {
                let idx = (c as usize).wrapping_sub(0x4E00);
                if idx < table.len() {
                    table[idx] = *initial;
                }
            }
        }
        table
    });
    let b = lut[(ch as usize) - 0x4E00];
    if b == 0 {
        None
    } else {
        Some(b as char)
    }
}

// ============================================================================
// 3. 搜索框即时速算（支持刚复制金额免重敲百分比续算）与闪念速记 / @建议
// ============================================================================

#[derive(Debug, Clone, PartialEq)]
pub struct InstantMathResult {
    pub expression_display: String,
    pub plain_value: String,
    pub rmb_uppercase: Option<String>,
    pub used_clipboard_context: bool,
}

pub fn evaluate_instant_math(
    query: &str,
    latest_clip_text: Option<&str>,
) -> Option<InstantMathResult> {
    let trimmed = query.trim();
    if trimmed.is_empty() || trimmed.len() > 96 {
        return None;
    }

    // 排除纯 11+ 位手机号/单号
    let pure_digits = trimmed.trim_start_matches('+');
    if pure_digits.len() >= 11 && pure_digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }

    let has_leading_eq = trimmed.starts_with('=') || trimmed.starts_with('＝');
    let clean_expr = trimmed
        .strip_prefix('=')
        .or_else(|| trimmed.strip_prefix('＝'))
        .map(str::trim)
        .unwrap_or(trimmed);
    if clean_expr.is_empty() {
        return None;
    }

    // 0. 优先检测离线日期加减、跨时区换算与 Unix 时间戳双向直算（如 `2026-11-24 + 90天`、`30天后`、`10:00 pst`、`ts 1763971200`）
    if let Some(temp_res) = evaluate_temporal_expression(clean_expr, has_leading_eq) {
        return Some(temp_res);
    }

    // 0.5 检测商业折扣、环比涨跌幅与程序员进制直算（如 `1280 85折`、`299 7.5折`、`12500 -> 16000`、`0xff`、`255 to hex`）
    if let Some(biz_res) = evaluate_business_and_radix(clean_expr, latest_clip_text) {
        return Some(biz_res);
    }

    // 0.6 检测离线色彩制式互转（`#1E5EFF` / `rgb(...)` / `hsl(...)`）与 WCAG 2.1 无障碍对比度直算（`#FFFFFF vs #1E5EFF`）
    if let Some(color_res) =
        evaluate_color_and_contrast(clean_expr, has_leading_eq, latest_clip_text)
    {
        return Some(color_res);
    }

    // 0.7 检测编程与数据库命名风格直转（`camel user_id` / `snake userOrderId` / `kebab ...` / `to snake` / `转驼峰`）
    if let Some(case_res) = evaluate_identifier_case_expr(clean_expr, latest_clip_text) {
        return Some(case_res);
    }

    // 1. 离线全能单位换算（存储 B/KB/MB/GB/TB、时长 ms/s/min/h/d、温度 C/F、重量长度 kg/lb、cm/in、km/mi）
    if let Some(unit_res) = evaluate_unit_conversion(clean_expr, has_leading_eq) {
        return Some(unit_res);
    }

    // 检测首字符是否为二元续算运算符（如 `* 13%`、`/ (1 + 6%)`、`+ 350`）
    let mut used_ctx = false;
    let full_expr = if clean_expr.starts_with(['*', '/', '×', '÷'])
        || ((clean_expr.starts_with('+') || clean_expr.starts_with('-'))
            && clean_expr.len() >= 2
            && clean_expr
                .chars()
                .nth(1)
                .map(|c| c.is_whitespace() || c.is_ascii_digit())
                .unwrap_or(false)
            && latest_clip_text.and_then(extract_leading_amount).is_some())
    {
        let base_num = latest_clip_text.and_then(extract_leading_amount)?;
        used_ctx = true;
        format!("{base_num} {clean_expr}")
    } else {
        clean_expr.to_string()
    };

    // 普通搜索词必须包含至少一个算术运算符或 `=` 前缀才触发速算卡
    let has_op = trimmed.starts_with('=')
        || full_expr
            .chars()
            .any(|c| matches!(c, '+' | '-' | '*' | '/' | '×' | '÷' | '%' | '万' | '亿'));
    if !has_op {
        return None;
    }

    let normalized = normalize_math_expr(&full_expr)?;
    let val = eval_expr(&normalized)?;
    if !val.is_finite() {
        return None;
    }

    // 若只是单个裸正数且没有显式 `=` 也没有单位转换，不弹速算卡干扰数字搜索
    if !trimmed.starts_with('=')
        && !used_ctx
        && !full_expr
            .chars()
            .skip(1)
            .any(|c| matches!(c, '+' | '-' | '*' | '/' | '×' | '÷' | '%' | '万' | '亿'))
    {
        return None;
    }

    let plain = format_clean_decimal(val);
    let rmb = if val >= 0.0 && val < 1_000_000_000_000.0 {
        let abs_fixed = format!("{:.2}", val.abs());
        let (i_part, f_part) = abs_fixed.split_once('.').unwrap_or((&abs_fixed, "00"));
        to_chinese_uppercase_rmb(i_part, Some(f_part))
    } else {
        None
    };

    Some(InstantMathResult {
        expression_display: full_expr,
        plain_value: plain,
        rmb_uppercase: rmb,
        used_clipboard_context: used_ctx,
    })
}

fn timezone_offset_minutes(code: &str) -> Option<(i32, &'static str)> {
    match code.to_ascii_lowercase().as_str() {
        "utc" | "gmt" => Some((0, "UTC")),
        "cst" | "bj" | "bjt" | "hkt" | "sgt" => Some((480, "UTC+8")),
        "jst" | "kst" => Some((540, "UTC+9")),
        "pst" => Some((-480, "PST")),
        "pdt" => Some((-420, "PDT")),
        "est" => Some((-300, "EST")),
        "edt" => Some((-240, "EDT")),
        "cet" => Some((60, "CET")),
        "cest" => Some((120, "CEST")),
        "bst" => Some((120, "BST")),
        "ist" => Some((330, "IST")),
        "aest" => Some((600, "AEST")),
        _ => None,
    }
}

fn civil_from_days(z: i64) -> (i32, u32, u32, &'static str) {
    let z_shift = z + 719_468;
    let era = if z_shift >= 0 {
        z_shift
    } else {
        z_shift - 146_096
    } / 146_097;
    let doe = z_shift - era * 146_097;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let mut y = (yoe + era * 400) as i32;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    if m <= 2 {
        y += 1;
    }
    let wd_idx = (z + 4).rem_euclid(7) as usize;
    const WD_NAMES: [&str; 7] = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"];
    (y, m, d, WD_NAMES[wd_idx])
}

fn days_from_civil(year: i32, month: u32, day: u32) -> Option<i64> {
    if !(1970..=9999).contains(&year) || !(1..=12).contains(&month) || !(1..=31).contains(&day) {
        return None;
    }
    let y = (year - if month <= 2 { 1 } else { 0 }) as i64;
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = month as i64 + if month > 2 { -3 } else { 9 };
    let doy = (153 * mp + 2) / 5 + day as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let z = era * 146_097 + doe - 719_468;
    let (cy, cm, cd, _) = civil_from_days(z);
    if cy == year && cm == month && cd == day {
        Some(z)
    } else {
        None
    }
}

fn evaluate_temporal_expression(input: &str, has_leading_eq: bool) -> Option<InstantMathResult> {
    use regex_lite::Regex;
    use std::sync::OnceLock;

    let trimmed = input.trim();
    static EXPLICIT_DATE_RE: OnceLock<Regex> = OnceLock::new();
    static REL_DATE_RE: OnceLock<Regex> = OnceLock::new();
    static TZ_CONV_RE: OnceLock<Regex> = OnceLock::new();
    static TS_DATE_RE: OnceLock<Regex> = OnceLock::new();

    let exp_re = EXPLICIT_DATE_RE.get_or_init(|| {
        Regex::new(
            r"(?i)^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})\s*([+-])\s*(\d{1,4})\s*(天|日|周|星期|d|day|days|w|week|weeks)?$",
        )
        .unwrap()
    });
    if let Some(caps) = exp_re.captures(trimmed) {
        let y: i32 = caps.get(1)?.as_str().parse().ok()?;
        let mo: u32 = caps.get(2)?.as_str().parse().ok()?;
        let d: u32 = caps.get(3)?.as_str().parse().ok()?;
        let sign: i64 = if caps.get(4)?.as_str() == "-" { -1 } else { 1 };
        let n: i64 = caps.get(5)?.as_str().parse().ok()?;
        let base_z = days_from_civil(y, mo, d)?;
        let unit = caps
            .get(6)
            .map(|m| m.as_str().to_lowercase())
            .unwrap_or_else(|| "d".to_string());
        let mult = if unit == "周" || unit == "星期" || unit.starts_with('w') {
            7
        } else {
            1
        };
        let (ty, tm, td, wd) = civil_from_days(base_z + sign * n * mult);
        let iso = format!("{ty:04}-{tm:02}-{td:02}");
        return Some(InstantMathResult {
            expression_display: format!("{trimmed} · {wd}"),
            plain_value: iso,
            rmb_uppercase: None,
            used_clipboard_context: false,
        });
    }

    let rel_re = REL_DATE_RE.get_or_init(|| {
        Regex::new(
            r"(?i)^([+-]?\d{1,4})\s*(天|日|周|星期|d|day|days|w|week|weeks)\s*(后|之后|前|之前|later|ago)?$",
        )
        .unwrap()
    });
    if let Some(caps) = rel_re.captures(trimmed) {
        let num_str = caps.get(1)?.as_str();
        let raw_num: i64 = num_str.parse().ok()?;
        let has_sign = num_str.starts_with('+') || num_str.starts_with('-');
        let dir = caps
            .get(3)
            .map(|m| m.as_str().to_lowercase())
            .unwrap_or_default();
        if has_sign || !dir.is_empty() {
            let unit = caps.get(2)?.as_str().to_lowercase();
            let mult = if unit == "周" || unit == "星期" || unit.starts_with('w') {
                7
            } else {
                1
            };
            let mut delta = raw_num.abs() * mult;
            if num_str.starts_with('-') || dir == "前" || dir == "之前" || dir == "ago" {
                delta = -delta;
            }
            let now_secs = crate::model::now_unix_secs() as i64;
            let today_z = (now_secs + 8 * 3_600).div_euclid(86_400);
            let (ty, tm, td, wd) = civil_from_days(today_z + delta);
            let iso = format!("{ty:04}-{tm:02}-{td:02}");
            return Some(InstantMathResult {
                expression_display: format!("{trimmed} · {wd}"),
                plain_value: iso,
                rmb_uppercase: None,
                used_clipboard_context: false,
            });
        }
    }

    let lower = trimmed.to_ascii_lowercase();
    let is_ts_prefix = lower.starts_with("ts ") || lower.starts_with("unix ");
    if is_ts_prefix || has_leading_eq {
        let body = if is_ts_prefix {
            trimmed
                .split_once(char::is_whitespace)
                .map(|(_, r)| r.trim())
                .unwrap_or("")
        } else {
            trimmed
        };
        if (body.len() == 10 || body.len() == 13) && body.bytes().all(|b| b.is_ascii_digit()) {
            if let Ok(raw_int) = body.parse::<i64>() {
                let sec = if body.len() == 13 {
                    raw_int / 1_000
                } else {
                    raw_int
                };
                if (946_684_800..=4_102_444_800).contains(&sec) {
                    let bj_total = sec + 8 * 3_600;
                    let day_z = bj_total.div_euclid(86_400);
                    let rem = bj_total.rem_euclid(86_400);
                    let hh = rem / 3_600;
                    let mm = (rem % 3_600) / 60;
                    let ss = rem % 60;
                    let (cy, cm, cd, _) = civil_from_days(day_z);
                    let formatted = format!("{cy:04}-{cm:02}-{cd:02} {hh:02}:{mm:02}:{ss:02}");
                    return Some(InstantMathResult {
                        expression_display: format!("Unix {sec} (UTC+8)"),
                        plain_value: formatted,
                        rmb_uppercase: None,
                        used_clipboard_context: false,
                    });
                }
            }
        }
        if is_ts_prefix {
            let ts_re = TS_DATE_RE.get_or_init(|| {
                Regex::new(
                    r"(?i)^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?:\s+(\d{1,2}):(\d{2})(?::(\d{2}))?)?\s*(utc|z)?$",
                )
                .unwrap()
            });
            if let Some(caps) = ts_re.captures(body) {
                let y: i32 = caps.get(1)?.as_str().parse().ok()?;
                let mo: u32 = caps.get(2)?.as_str().parse().ok()?;
                let d: u32 = caps.get(3)?.as_str().parse().ok()?;
                let z = days_from_civil(y, mo, d)?;
                let hh: i64 = caps
                    .get(4)
                    .and_then(|m| m.as_str().parse().ok())
                    .unwrap_or(0);
                let mm: i64 = caps
                    .get(5)
                    .and_then(|m| m.as_str().parse().ok())
                    .unwrap_or(0);
                let ss: i64 = caps
                    .get(6)
                    .and_then(|m| m.as_str().parse().ok())
                    .unwrap_or(0);
                if !(0..=23).contains(&hh) || !(0..=59).contains(&mm) || !(0..=59).contains(&ss) {
                    return None;
                }
                let is_utc = caps.get(7).is_some();
                let tz_shift = if is_utc { 0 } else { 8 * 3_600 };
                let epoch_sec = z * 86_400 + hh * 3_600 + mm * 60 + ss - tz_shift;
                return Some(InstantMathResult {
                    expression_display: format!("{body} -> Unix 秒"),
                    plain_value: epoch_sec.to_string(),
                    rmb_uppercase: None,
                    used_clipboard_context: false,
                });
            }
        }
    }

    let tz_re = TZ_CONV_RE.get_or_init(|| {
        Regex::new(
            r"(?i)^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*([a-z]{2,4})(?:\s*(?:to|in|->|=>|转)\s*([a-z]{2,4}))?$",
        )
        .unwrap()
    });
    if let Some(caps) = tz_re.captures(trimmed) {
        let mut hour: i32 = caps.get(1)?.as_str().parse().ok()?;
        let has_colon = caps.get(2).is_some();
        let minute: i32 = caps
            .get(2)
            .and_then(|m| m.as_str().parse().ok())
            .unwrap_or(0);
        let ampm = caps
            .get(3)
            .map(|m| m.as_str().to_ascii_lowercase())
            .unwrap_or_default();
        let (src_min, _) = timezone_offset_minutes(caps.get(4)?.as_str())?;
        let dst_opt = caps.get(5).map(|m| m.as_str());
        if !has_colon && ampm.is_empty() && dst_opt.is_none() && !has_leading_eq {
            return None;
        }
        if !ampm.is_empty() {
            if !(1..=12).contains(&hour) {
                return None;
            }
            if ampm == "pm" && hour != 12 {
                hour += 12;
            }
            if ampm == "am" && hour == 12 {
                hour = 0;
            }
        }
        if !(0..=23).contains(&hour) || !(0..=59).contains(&minute) {
            return None;
        }
        let (dst_min, dst_lbl) = if let Some(dr) = dst_opt {
            timezone_offset_minutes(dr)?
        } else if src_min == 480 {
            (0, "UTC")
        } else {
            (480, "UTC+8")
        };
        if dst_min == src_min {
            return None;
        }
        let total = hour * 60 + minute - src_min + dst_min;
        let day_shift = total.div_euclid(1_440);
        let norm_min = total.rem_euclid(1_440);
        let out_hh = norm_min / 60;
        let out_mm = norm_min % 60;
        let suffix = if day_shift > 0 {
            format!(" (+{day_shift}天)")
        } else if day_shift < 0 {
            format!(" ({day_shift}天)")
        } else {
            String::new()
        };
        let plain = format!("{out_hh:02}:{out_mm:02}{suffix}");
        return Some(InstantMathResult {
            expression_display: format!("{trimmed} -> {dst_lbl}"),
            plain_value: plain,
            rmb_uppercase: None,
            used_clipboard_context: false,
        });
    }

    None
}

fn evaluate_business_and_radix(
    input: &str,
    latest_clip_text: Option<&str>,
) -> Option<InstantMathResult> {
    use regex_lite::Regex;
    use std::sync::OnceLock;

    let trimmed = input.trim();
    static CN_DISC_RE: OnceLock<Regex> = OnceLock::new();
    static PCT_DELTA_RE: OnceLock<Regex> = OnceLock::new();
    static RADIX_RE: OnceLock<Regex> = OnceLock::new();
    static INVOICE_TAX_RE: OnceLock<Regex> = OnceLock::new();
    static SALARY_WAGE_RE: OnceLock<Regex> = OnceLock::new();
    static AA_SPLIT_RE: OnceLock<Regex> = OnceLock::new();

    // 0a. 职场法定计薪折算（国家标准 21.75 计薪日 × 8h = 174h/月）：`25000 日薪`、`25k 时薪`、`2.5万 加班费` 或剪贴板续算 `日薪`
    let salary_re = SALARY_WAGE_RE.get_or_init(|| {
        Regex::new(
            r"^(?:[¥￥$]?\s*(\d[\d,]*(?:\.\d+)?)\s*([kKwW万])?\s*)?(?:算|折算|转)?(日薪|时薪|月薪|加班费)$",
        )
        .unwrap()
    });
    if let Some(caps) = salary_re.captures(trimmed) {
        let mode_str = caps.get(3)?.as_str();
        let (monthly_salary, used_ctx) = if let Some(amt_m) = caps.get(1) {
            let raw_num: f64 = amt_m.as_str().replace(',', "").parse().ok()?;
            if raw_num <= 0.0 {
                return None;
            }
            let mul = match caps.get(2).map(|m| m.as_str()) {
                Some("k") | Some("K") => 1_000.0,
                Some("w") | Some("W") | Some("万") => 10_000.0,
                _ => 1.0,
            };
            (raw_num * mul, false)
        } else {
            let ctx_num = latest_clip_text.and_then(extract_leading_amount)?;
            let v: f64 = ctx_num.parse().ok()?;
            if v <= 0.0 {
                return None;
            }
            (v, true)
        };
        let daily = (monthly_salary / 21.75 * 100.0).round() / 100.0;
        let hourly = (monthly_salary / 174.0 * 100.0).round() / 100.0;
        let ot15 = (hourly * 1.5 * 100.0).round() / 100.0;
        let ot20 = (hourly * 2.0 * 100.0).round() / 100.0;
        let daily_str = format_clean_decimal(daily);
        let hourly_str = format_clean_decimal(hourly);
        let ot15_str = format_clean_decimal(ot15);
        let ot20_str = format_clean_decimal(ot20);
        let wants_hourly = mode_str == "时薪" || mode_str == "加班费";
        let (plain_out, expr_disp) = if wants_hourly {
            (
                hourly_str,
                format!("时薪 (日薪 {daily_str} · 1.5倍 {ot15_str}/h · 2倍 {ot20_str}/h)"),
            )
        } else {
            (
                daily_str,
                format!("日薪 (时薪 {hourly_str} · 21.75天 · 1.5倍 {ot15_str}/h)"),
            )
        };
        return Some(InstantMathResult {
            expression_display: expr_disp,
            plain_value: plain_out,
            rmb_uppercase: None,
            used_clipboard_context: used_ctx,
        });
    }

    // 0b. 多人 AA 平摊零尾差直算：`1286 / 6人`、`1286 aa 6` 或复制账单金额后直接敲 `aa 6` / `平摊 6人`
    let aa_re = AA_SPLIT_RE.get_or_init(|| {
        Regex::new(
            r"^(?:[¥￥$]?\s*(\d[\d,]*(?:\.\d+)?)\s*)?(?:(?:aa|AA|平摊|分摊|均摊)\s*(\d{1,5})\s*人?|[/÷]\s*(\d{1,5})\s*人)$",
        )
        .unwrap()
    });
    if let Some(caps) = aa_re.captures(trimmed) {
        let cnt_str = caps.get(2).or_else(|| caps.get(3))?.as_str();
        let people: i64 = cnt_str.parse().ok()?;
        if !(2..=10_000).contains(&people) {
            return None;
        }
        let (total_amt, used_ctx) = if let Some(amt_m) = caps.get(1) {
            let v: f64 = amt_m.as_str().replace(',', "").parse().ok()?;
            if v <= 0.0 {
                return None;
            }
            (v, false)
        } else {
            let ctx_num = latest_clip_text.and_then(extract_leading_amount)?;
            let v: f64 = ctx_num.parse().ok()?;
            if v <= 0.0 {
                return None;
            }
            (v, true)
        };
        let total_cents = (total_amt * 100.0).round() as i64;
        let per_cents = ((total_cents as f64) / (people as f64)).round() as i64;
        let diff_cents = per_cents * people - total_cents;
        let per_val = per_cents as f64 / 100.0;
        let per_str = format_clean_decimal(per_val);
        let diff_desc = if diff_cents == 0 {
            "整除无尾差".to_string()
        } else if diff_cents > 0 {
            format!("合计多收 +{:.2}", diff_cents as f64 / 100.0)
        } else {
            format!("合计尾差 {:.2}", diff_cents as f64 / 100.0)
        };
        let rmb = if per_val >= 0.0 && per_val < 1_000_000_000_000.0 {
            let abs_fixed = format!("{:.2}", per_val.abs());
            let (i_part, f_part) = abs_fixed.split_once('.').unwrap_or((&abs_fixed, "00"));
            to_chinese_uppercase_rmb(i_part, Some(f_part))
        } else {
            None
        };
        return Some(InstantMathResult {
            expression_display: format!("每人应付 ({people}人AA · {diff_desc})"),
            plain_value: per_str,
            rmb_uppercase: rmb,
            used_clipboard_context: used_ctx,
        });
    }

    // 0. 零尾差发票价税分离 & 加税开票直算：`12800 含税 6%`、`1130 含税`（默认 13%）、`10000 加税 6%` 或剪贴板免重敲 `含税 6%`
    let tax_re = INVOICE_TAX_RE.get_or_init(|| {
        Regex::new(
            r"^(?:[¥￥$]?\s*(\d[\d,]*(?:\.\d+)?)\s*)?(含税|价税分离|去税|除税|加税|不含税|税前)\s*(?:(\d{1,2}(?:\.\d{1,2})?)\s*[%％]?)?$",
        )
        .unwrap()
    });
    if let Some(caps) = tax_re.captures(trimmed) {
        let mode_str = caps.get(2)?.as_str();
        let tax_pct: f64 = if let Some(rate_m) = caps.get(3) {
            rate_m.as_str().parse().ok()?
        } else {
            13.0
        };
        if !(tax_pct > 0.0 && tax_pct <= 50.0) {
            return None;
        }
        let (base_amt, used_ctx) = if let Some(amt_m) = caps.get(1) {
            let v: f64 = amt_m.as_str().replace(',', "").parse().ok()?;
            if v <= 0.0 {
                return None;
            }
            (v, false)
        } else {
            let ctx_num = latest_clip_text.and_then(extract_leading_amount)?;
            let v: f64 = ctx_num.parse().ok()?;
            if v <= 0.0 {
                return None;
            }
            (v, true)
        };
        let rate = tax_pct / 100.0;
        let rate_lbl = format!("{}%", format_clean_decimal(tax_pct));
        let is_inclusive = matches!(mode_str, "含税" | "价税分离" | "去税" | "除税");
        let total_input_cents = (base_amt * 100.0).round() as i64;
        let (primary_cents, expr_disp) = if is_inclusive {
            let net_cents = ((total_input_cents as f64) / (1.0 + rate)).round() as i64;
            let diff_tax_cents = total_input_cents - net_cents;
            let tax_str = format_clean_decimal(diff_tax_cents as f64 / 100.0);
            (
                net_cents,
                format!(
                    "不含税 (税额 {tax_str} · {rate_lbl})"
                ),
            )
        } else {
            let gross_cents = ((total_input_cents as f64) * (1.0 + rate)).round() as i64;
            let added_tax_cents = gross_cents - total_input_cents;
            let tax_str = format_clean_decimal(added_tax_cents as f64 / 100.0);
            (
                gross_cents,
                format!(
                    "含税总价 (税额 {tax_str} · {rate_lbl})"
                ),
            )
        };
        let primary_val = primary_cents as f64 / 100.0;
        let plain_out = format_clean_decimal(primary_val);
        let rmb = if primary_val >= 0.0 && primary_val < 1_000_000_000_000.0 {
            let abs_fixed = format!("{:.2}", primary_val.abs());
            let (i_part, f_part) = abs_fixed.split_once('.').unwrap_or((&abs_fixed, "00"));
            to_chinese_uppercase_rmb(i_part, Some(f_part))
        } else {
            None
        };
        return Some(InstantMathResult {
            expression_display: expr_disp,
            plain_value: plain_out,
            rmb_uppercase: rmb,
            used_clipboard_context: used_ctx,
        });
    }

    // 1. 中式商业折扣秒算：`1280 85折`、`299 7.5折`、或结合剪贴板首条金额输入 `85折`
    let disc_re = CN_DISC_RE.get_or_init(|| {
        Regex::new(
            r"^(?:[¥￥$]?\s*(\d[\d,]*(?:\.\d+)?)\s*(?:[*×xX]\s*|\s+|打))?打?\s*(\d(?:\.\d{1,2})?|[1-9]\d)\s*折$",
        )
        .unwrap()
    });
    if let Some(caps) = disc_re.captures(trimmed) {
        let rate_str = caps.get(2)?.as_str();
        let rate_val: f64 = rate_str.parse().ok()?;
        let factor = if rate_str.contains('.') || rate_val < 10.0 {
            rate_val / 10.0
        } else {
            rate_val / 100.0
        };
        if !(factor > 0.0 && factor < 1.0) {
            return None;
        }
        let (base_amt, used_ctx) = if let Some(amt_m) = caps.get(1) {
            let v: f64 = amt_m.as_str().replace(',', "").parse().ok()?;
            if v <= 0.0 {
                return None;
            }
            (v, false)
        } else {
            let ctx_num = latest_clip_text.and_then(extract_leading_amount)?;
            let v: f64 = ctx_num.parse().ok()?;
            if v <= 0.0 {
                return None;
            }
            (v, true)
        };
        let discounted = base_amt * factor;
        let plain = format_clean_decimal(discounted);
        let rmb = if discounted >= 0.0 && discounted < 1_000_000_000_000.0 {
            let abs_fixed = format!("{:.2}", discounted.abs());
            let (i_part, f_part) = abs_fixed.split_once('.').unwrap_or((&abs_fixed, "00"));
            to_chinese_uppercase_rmb(i_part, Some(f_part))
        } else {
            None
        };
        return Some(InstantMathResult {
            expression_display: format!("{} × {rate_str}折", format_clean_decimal(base_amt)),
            plain_value: plain,
            rmb_uppercase: rmb,
            used_clipboard_context: used_ctx,
        });
    }

    // 2. 两点涨跌幅与倍数秒算：`12500 -> 16000` / `200 vs 150`
    let delta_re = PCT_DELTA_RE.get_or_init(|| {
        Regex::new(
            r"^[¥￥$]?\s*(-?\d[\d,]*(?:\.\d+)?)\s*(?:->|=>|vs|VS)\s*[¥￥$]?\s*(-?\d[\d,]*(?:\.\d+)?)$",
        )
        .unwrap()
    });
    if let Some(caps) = delta_re.captures(trimmed) {
        let a_str = caps.get(1)?.as_str();
        let b_str = caps.get(2)?.as_str();
        let a: f64 = a_str.replace(',', "").parse().ok()?;
        let b: f64 = b_str.replace(',', "").parse().ok()?;
        if a.abs() > 1e-9 && (a - b).abs() > 1e-12 {
            let pct = ((b - a) / a.abs()) * 100.0;
            let diff = b - a;
            let sign = if pct > 0.0 { "+" } else { "" };
            let pct_plain = format!("{sign}{}%", format_clean_decimal(pct));
            let diff_sign = if diff > 0.0 { "+" } else { "" };
            return Some(InstantMathResult {
                expression_display: format!(
                    "{a_str} -> {b_str} (差额 {diff_sign}{})",
                    format_clean_decimal(diff)
                ),
                plain_value: pct_plain,
                rmb_uppercase: None,
                used_clipboard_context: false,
            });
        }
    }

    // 3. 程序员十六进制 / 二进制双向秒转：`0xff`、`0b101010`、`255 to hex`、`42 to bin`
    let radix_re = RADIX_RE.get_or_init(|| {
        Regex::new(
            r"(?i)^(?:0x([0-9a-f]{2,16})|0b([01]{4,63})|(\d{1,19})\s+(?:to|in|->|=>|转)\s*(hex|bin|binary))$",
        )
        .unwrap()
    });
    if let Some(caps) = radix_re.captures(trimmed) {
        if let Some(hex_m) = caps.get(1) {
            let val = u64::from_str_radix(hex_m.as_str(), 16).ok()?;
            return Some(InstantMathResult {
                expression_display: format!("0x{} -> DEC", hex_m.as_str().to_ascii_uppercase()),
                plain_value: val.to_string(),
                rmb_uppercase: None,
                used_clipboard_context: false,
            });
        }
        if let Some(bin_m) = caps.get(2) {
            let val = u64::from_str_radix(bin_m.as_str(), 2).ok()?;
            return Some(InstantMathResult {
                expression_display: format!("0b{} -> DEC (0x{val:X})", bin_m.as_str()),
                plain_value: val.to_string(),
                rmb_uppercase: None,
                used_clipboard_context: false,
            });
        }
        if let (Some(dec_m), Some(dst_m)) = (caps.get(3), caps.get(4)) {
            let val: u64 = dec_m.as_str().parse().ok()?;
            let dst = dst_m.as_str().to_ascii_lowercase();
            let out_str = if dst == "hex" {
                format!("0x{val:X}")
            } else {
                format!("0b{val:b}")
            };
            return Some(InstantMathResult {
                expression_display: format!("{val} -> {}", dst.to_ascii_uppercase()),
                plain_value: out_str,
                rmb_uppercase: None,
                used_clipboard_context: false,
            });
        }
    }

    None
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum WinColorSource {
    Hex,
    Rgb,
    Hsl,
}

#[derive(Clone, Copy)]
struct WinParsedColor {
    r: f64,
    g: f64,
    b: f64,
    a: f64,
    source: WinColorSource,
}

fn hsl_to_rgb_norm(h: f64, s: f64, l: f64) -> (f64, f64, f64) {
    let hue = ((h % 360.0) + 360.0) % 360.0;
    let c = (1.0 - (2.0 * l - 1.0).abs()) * s;
    let x = c * (1.0 - ((hue / 60.0) % 2.0 - 1.0).abs());
    let m = l - c / 2.0;
    let (r1, g1, b1) = if hue < 60.0 {
        (c, x, 0.0)
    } else if hue < 120.0 {
        (x, c, 0.0)
    } else if hue < 180.0 {
        (0.0, c, x)
    } else if hue < 240.0 {
        (0.0, x, c)
    } else if hue < 300.0 {
        (x, 0.0, c)
    } else {
        (c, 0.0, x)
    };
    (
        (r1 + m).clamp(0.0, 1.0),
        (g1 + m).clamp(0.0, 1.0),
        (b1 + m).clamp(0.0, 1.0),
    )
}

fn rgb_to_hsl_deg(r: f64, g: f64, b: f64) -> (i32, i32, i32) {
    let max_c = r.max(g).max(b);
    let min_c = r.min(g).min(b);
    let delta = max_c - min_c;
    let l = (max_c + min_c) / 2.0;
    let mut h = 0.0;
    let mut s = 0.0;
    if delta > 1e-7 {
        s = delta / (1.0 - (2.0 * l - 1.0).abs());
        if (max_c - r).abs() < 1e-9 {
            h = 60.0 * (((g - b) / delta) % 6.0);
        } else if (max_c - g).abs() < 1e-9 {
            h = 60.0 * (((b - r) / delta) + 2.0);
        } else {
            h = 60.0 * (((r - g) / delta) + 4.0);
        }
        if h < 0.0 {
            h += 360.0;
        }
    }
    (
        (h.round() as i32) % 360,
        (s * 100.0).round() as i32,
        (l * 100.0).round() as i32,
    )
}

fn format_win_hex(c: WinParsedColor) -> String {
    let r = (c.r * 255.0).round() as u8;
    let g = (c.g * 255.0).round() as u8;
    let b = (c.b * 255.0).round() as u8;
    if c.a < 0.995 {
        let a = (c.a * 255.0).round() as u8;
        format!("#{r:02X}{g:02X}{b:02X}{a:02X}")
    } else {
        format!("#{r:02X}{g:02X}{b:02X}")
    }
}

fn format_win_rgb(c: WinParsedColor) -> String {
    let r = (c.r * 255.0).round() as u8;
    let g = (c.g * 255.0).round() as u8;
    let b = (c.b * 255.0).round() as u8;
    if c.a < 0.995 {
        format!("rgba({r}, {g}, {b}, {:.2})", c.a)
    } else {
        format!("rgb({r}, {g}, {b})")
    }
}

fn format_win_hsl(c: WinParsedColor) -> String {
    let (h, s, l) = rgb_to_hsl_deg(c.r, c.g, c.b);
    if c.a < 0.995 {
        format!("hsla({h}, {s}%, {l}%, {:.2})", c.a)
    } else {
        format!("hsl({h}, {s}%, {l}%)")
    }
}

fn parse_single_color_token(raw: &str, allow_short_hex: bool) -> Option<WinParsedColor> {
    use regex_lite::Regex;
    use std::sync::OnceLock;
    let s = raw.trim();
    if !(4..=64).contains(&s.len()) {
        return None;
    }

    static HEX_RE: OnceLock<Regex> = OnceLock::new();
    static RGB_RE: OnceLock<Regex> = OnceLock::new();
    static HSL_RE: OnceLock<Regex> = OnceLock::new();

    let hex_re = HEX_RE
        .get_or_init(|| Regex::new(r"^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$").unwrap());
    if let Some(caps) = hex_re.captures(s) {
        let hx = caps.get(1)?.as_str();
        if hx.len() == 3 && !allow_short_hex {
            return None;
        }
        let val = u64::from_str_radix(hx, 16).ok()?;
        return match hx.len() {
            3 => Some(WinParsedColor {
                r: ((val >> 8) & 0xF) as f64 / 15.0,
                g: ((val >> 4) & 0xF) as f64 / 15.0,
                b: (val & 0xF) as f64 / 15.0,
                a: 1.0,
                source: WinColorSource::Hex,
            }),
            6 => Some(WinParsedColor {
                r: ((val >> 16) & 0xFF) as f64 / 255.0,
                g: ((val >> 8) & 0xFF) as f64 / 255.0,
                b: (val & 0xFF) as f64 / 255.0,
                a: 1.0,
                source: WinColorSource::Hex,
            }),
            8 => Some(WinParsedColor {
                r: ((val >> 24) & 0xFF) as f64 / 255.0,
                g: ((val >> 16) & 0xFF) as f64 / 255.0,
                b: ((val >> 8) & 0xFF) as f64 / 255.0,
                a: (val & 0xFF) as f64 / 255.0,
                source: WinColorSource::Hex,
            }),
            _ => None,
        };
    }

    let rgb_re = RGB_RE.get_or_init(|| {
        Regex::new(
            r"(?i)^rgba?\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})(?:\s*,\s*([0-9]*\.?[0-9]+))?\s*\)$",
        )
        .unwrap()
    });
    if let Some(caps) = rgb_re.captures(s) {
        let ri: u32 = caps.get(1)?.as_str().parse().ok()?;
        let gi: u32 = caps.get(2)?.as_str().parse().ok()?;
        let bi: u32 = caps.get(3)?.as_str().parse().ok()?;
        if ri <= 255 && gi <= 255 && bi <= 255 {
            let a = caps
                .get(4)
                .and_then(|m| m.as_str().parse::<f64>().ok())
                .map(|v| v.clamp(0.0, 1.0))
                .unwrap_or(1.0);
            return Some(WinParsedColor {
                r: ri as f64 / 255.0,
                g: gi as f64 / 255.0,
                b: bi as f64 / 255.0,
                a,
                source: WinColorSource::Rgb,
            });
        }
    }

    let hsl_re = HSL_RE.get_or_init(|| {
        Regex::new(
            r"(?i)^hsla?\(\s*(\d{1,3}(?:\.\d+)?)\s*,\s*(\d{1,3}(?:\.\d+)?)%\s*,\s*(\d{1,3}(?:\.\d+)?)%(?:\s*,\s*([0-9]*\.?[0-9]+))?\s*\)$",
        )
        .unwrap()
    });
    if let Some(caps) = hsl_re.captures(s) {
        let hd: f64 = caps.get(1)?.as_str().parse().ok()?;
        let sp: f64 = caps.get(2)?.as_str().parse().ok()?;
        let lp: f64 = caps.get(3)?.as_str().parse().ok()?;
        if (0.0..=360.0).contains(&hd) && (0.0..=100.0).contains(&sp) && (0.0..=100.0).contains(&lp)
        {
            let a = caps
                .get(4)
                .and_then(|m| m.as_str().parse::<f64>().ok())
                .map(|v| v.clamp(0.0, 1.0))
                .unwrap_or(1.0);
            let (r, g, b) = hsl_to_rgb_norm(hd, sp / 100.0, lp / 100.0);
            return Some(WinParsedColor {
                r,
                g,
                b,
                a,
                source: WinColorSource::Hsl,
            });
        }
    }

    None
}

fn wcag_relative_luminance(c: WinParsedColor) -> f64 {
    fn lin(v: f64) -> f64 {
        if v <= 0.04045 {
            v / 12.92
        } else {
            ((v + 0.055) / 1.055).powf(2.4)
        }
    }
    0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
}

/// 供卡片动作管线识别单行颜色色值并生成 HEX / RGB / HSL 一键互转动作
pub fn analyze_card_color_actions(raw: &str) -> Vec<(&'static str, String, String, String)> {
    let trimmed = raw.trim();
    let Some(c) = parse_single_color_token(trimmed, true) else {
        return Vec::new();
    };
    let hex = format_win_hex(c);
    let rgb = format_win_rgb(c);
    let hsl = format_win_hsl(c);
    let mut out = Vec::new();
    if !hex.eq_ignore_ascii_case(trimmed) {
        out.push(("color-hex", hex.clone(), hex.clone(), format!("已转换色值为 {hex}")));
    }
    if !rgb.eq_ignore_ascii_case(trimmed) {
        out.push(("color-rgb", "转 RGB".to_string(), rgb.clone(), format!("已转换为 {rgb}")));
    }
    if c.source != WinColorSource::Hsl {
        out.push(("color-hsl", "转 HSL".to_string(), hsl.clone(), format!("已转换为 {hsl}")));
    }
    out
}

fn evaluate_color_and_contrast(
    input: &str,
    has_leading_eq: bool,
    latest_clip_text: Option<&str>,
) -> Option<InstantMathResult> {
    use regex_lite::Regex;
    use std::sync::OnceLock;

    let trimmed = input.trim();
    static CONTRAST_RE: OnceLock<Regex> = OnceLock::new();
    static TAIL_TO_RE: OnceLock<Regex> = OnceLock::new();

    let contrast_re = CONTRAST_RE.get_or_init(|| {
        Regex::new(
            r"(?i)^(?:(?:对比|contrast)\s*(#\S+|rgba?\([^)]+\)|hsla?\([^)]+\))\s+(#\S+|rgba?\([^)]+\)|hsla?\([^)]+\))|(#\S+|rgba?\([^)]+\)|hsla?\([^)]+\))\s+(?:vs|on|对比|with)\s+(#\S+|rgba?\([^)]+\)|hsla?\([^)]+\))|(?:vs|on|对比)\s+(#\S+|rgba?\([^)]+\)|hsla?\([^)]+\)))$",
        )
        .unwrap()
    });
    if let Some(caps) = contrast_re.captures(trimmed) {
        let pair_opt: Option<(&str, &str, bool)> =
            if let (Some(m1), Some(m2)) = (caps.get(1), caps.get(2)) {
                Some((m1.as_str(), m2.as_str(), false))
            } else if let (Some(m3), Some(m4)) = (caps.get(3), caps.get(4)) {
                Some((m3.as_str(), m4.as_str(), false))
            } else if let Some(m5) = caps.get(5) {
                latest_clip_text
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .map(|clip| (clip, m5.as_str(), true))
            } else {
                None
            };

        if let Some((tok_a, tok_b, used_ctx)) = pair_opt {
            if let (Some(col_a), Some(col_b)) = (
                parse_single_color_token(tok_a, true),
                parse_single_color_token(tok_b, true),
            ) {
                let lum_a = wcag_relative_luminance(col_a);
                let lum_b = wcag_relative_luminance(col_b);
                let ratio = (lum_a.max(lum_b) + 0.05) / (lum_a.min(lum_b) + 0.05);
                let ratio_str = format!("{ratio:.2}:1");
                let grade = if ratio >= 7.0 {
                    "WCAG AAA 极佳"
                } else if ratio >= 4.5 {
                    "WCAG AA 达标（大字 AAA）"
                } else if ratio >= 3.0 {
                    "仅大字 AA 达标"
                } else {
                    "未达标（对比偏弱）"
                };
                return Some(InstantMathResult {
                    expression_display: format!(
                        "{} vs {} · {grade}",
                        format_win_hex(col_a),
                        format_win_hex(col_b)
                    ),
                    plain_value: ratio_str,
                    rmb_uppercase: None,
                    used_clipboard_context: used_ctx,
                });
            }
        }
    }

    let tail_re = TAIL_TO_RE
        .get_or_init(|| Regex::new(r"(?i)^(.+?)\s+(?:to|in|->|=>|转)\s*(hex|rgb|hsl)$").unwrap());
    let (candidate, dst_fmt): (&str, Option<String>) = if let Some(caps) = tail_re.captures(trimmed)
    {
        (
            caps.get(1)?.as_str(),
            Some(caps.get(2)?.as_str().to_ascii_lowercase()),
        )
    } else {
        (trimmed, None)
    };

    let parsed = parse_single_color_token(candidate, has_leading_eq || dst_fmt.is_some())?;
    let hex_str = format_win_hex(parsed);
    let rgb_str = format_win_rgb(parsed);
    let hsl_str = format_win_hsl(parsed);

    let (primary_out, expr_disp) = if let Some(dst) = dst_fmt.as_deref() {
        match dst {
            "hex" => (hex_str.clone(), format!("{rgb_str} -> HEX")),
            "hsl" => (hsl_str.clone(), format!("{hex_str} -> HSL")),
            _ => (rgb_str.clone(), format!("{hex_str} -> RGB")),
        }
    } else {
        match parsed.source {
            WinColorSource::Hex => (rgb_str.clone(), format!("{hex_str} · {hsl_str}")),
            WinColorSource::Rgb => (hex_str.clone(), format!("{rgb_str} · {hsl_str}")),
            WinColorSource::Hsl => (hex_str.clone(), format!("{hsl_str} · {rgb_str}")),
        }
    };

    Some(InstantMathResult {
        expression_display: expr_disp,
        plain_value: primary_out,
        rmb_uppercase: None,
        used_clipboard_context: false,
    })
}

fn tokenize_identifier_words(raw: &str) -> Vec<String> {
    let s = raw.trim();
    if s.is_empty()
        || !s
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b' '))
    {
        return Vec::new();
    }
    let bytes = s.as_bytes();
    let mut norm = String::with_capacity(bytes.len() + 8);
    for i in 0..bytes.len() {
        let b = bytes[i];
        if matches!(b, b'_' | b'-' | b' ') {
            norm.push(' ');
            continue;
        }
        if i > 0 {
            let prev = bytes[i - 1];
            let prev_lower_or_digit = prev.is_ascii_lowercase() || prev.is_ascii_digit();
            let next_lower = bytes
                .get(i + 1)
                .map(|nb| nb.is_ascii_lowercase())
                .unwrap_or(false);
            if b.is_ascii_uppercase()
                && (prev_lower_or_digit || (prev.is_ascii_uppercase() && next_lower))
            {
                norm.push(' ');
            }
        }
        norm.push(b as char);
    }
    norm.split_whitespace()
        .map(|w| w.to_ascii_lowercase())
        .filter(|w| !w.is_empty())
        .collect()
}

fn capitalize_ascii_word(w: &str) -> String {
    let mut chars = w.chars();
    match chars.next() {
        Some(first) => format!("{}{}", first.to_ascii_uppercase(), chars.as_str()),
        None => String::new(),
    }
}

/// 供卡片动作管线识别单行编程标识符并生成 camelCase / snake_case / UPPER_CASE 互转动作
pub fn analyze_card_identifier_case_actions(
    raw: &str,
) -> Vec<(&'static str, String, String, String)> {
    let trimmed = raw.trim();
    let words = tokenize_identifier_words(trimmed);
    if words.len() < 2 {
        return Vec::new();
    }
    let camel = format!(
        "{}{}",
        words[0],
        words[1..]
            .iter()
            .map(|w| capitalize_ascii_word(w))
            .collect::<String>()
    );
    let snake = words.join("_");
    let upper = words
        .iter()
        .map(|w| w.to_ascii_uppercase())
        .collect::<Vec<_>>()
        .join("_");
    let mut out = Vec::new();
    if camel != trimmed {
        out.push((
            "case-camel",
            camel.clone(),
            camel.clone(),
            format!("已转为驼峰 {camel}"),
        ));
    }
    if snake != trimmed {
        out.push((
            "case-snake",
            snake.clone(),
            snake.clone(),
            format!("已转为下划线 {snake}"),
        ));
    }
    if upper != trimmed && out.len() < 3 {
        out.push((
            "case-const",
            "UPPER_CASE".to_string(),
            upper,
            "已转为常量命名".to_string(),
        ));
    }
    out
}

fn evaluate_identifier_case_expr(
    input: &str,
    latest_clip_text: Option<&str>,
) -> Option<InstantMathResult> {
    use regex_lite::Regex;
    use std::sync::OnceLock;

    let trimmed = input.trim();
    static CASE_PFX_RE: OnceLock<Regex> = OnceLock::new();
    static CASE_SFX_RE: OnceLock<Regex> = OnceLock::new();

    let pfx_re = CASE_PFX_RE.get_or_init(|| {
        Regex::new(
            r"(?i)^(camel|camelcase|pascal|pascalcase|snake|snakecase|kebab|kebabcase|const|constant|upper|转驼峰|驼峰|转下划线|下划线|转短横线|转常量)\s+([A-Za-z0-9_\-\s]{2,96})$",
        )
        .unwrap()
    });
    let sfx_re = CASE_SFX_RE.get_or_init(|| {
        Regex::new(
            r"(?i)^(?:([A-Za-z0-9_\-]{2,96})\s+)?(?:to|in|->|=>|转)\s*(camel|camelcase|pascal|pascalcase|snake|snakecase|kebab|kebabcase|const|constant|驼峰|下划线|短横线|常量)$",
        )
        .unwrap()
    });

    let (style, ident, used_ctx): (String, &str, bool) = if let Some(caps) = pfx_re.captures(trimmed)
    {
        (
            caps.get(1)?.as_str().to_lowercase(),
            caps.get(2)?.as_str(),
            false,
        )
    } else if let Some(caps) = sfx_re.captures(trimmed) {
        let st = caps.get(2)?.as_str().to_lowercase();
        if let Some(id_m) = caps.get(1) {
            (st, id_m.as_str(), false)
        } else {
            let clip = latest_clip_text
                .map(str::trim)
                .filter(|c| (2..=96).contains(&c.len()))?;
            (st, clip, true)
        }
    } else {
        return None;
    };

    let words = tokenize_identifier_words(ident);
    if words.len() < 2 {
        return None;
    }

    let (out_txt, lbl) = match style.as_str() {
        "camel" | "camelcase" | "驼峰" | "转驼峰" => (
            format!(
                "{}{}",
                words[0],
                words[1..]
                    .iter()
                    .map(|w| capitalize_ascii_word(w))
                    .collect::<String>()
            ),
            "camelCase",
        ),
        "pascal" | "pascalcase" => (
            words
                .iter()
                .map(|w| capitalize_ascii_word(w))
                .collect::<String>(),
            "PascalCase",
        ),
        "kebab" | "kebabcase" | "短横线" | "转短横线" => (words.join("-"), "kebab-case"),
        "const" | "constant" | "upper" | "常量" | "转常量" => (
            words
                .iter()
                .map(|w| w.to_ascii_uppercase())
                .collect::<Vec<_>>()
                .join("_"),
            "UPPER_SNAKE",
        ),
        _ => (words.join("_"), "snake_case"),
    };

    Some(InstantMathResult {
        expression_display: format!("{ident} -> {lbl}"),
        plain_value: out_txt,
        rmb_uppercase: None,
        used_clipboard_context: used_ctx,
    })
}

#[derive(Clone, Copy)]
enum WinUnitFamily {
    DataBytes(f64, &'static str),
    DurationSec(f64, &'static str),
    TempC,
    TempF,
    MassKg(f64, &'static str),
    LengthCm(f64, &'static str),
}

fn classify_unit_token(raw_tok: &str, explicit_syntax: bool) -> Option<WinUnitFamily> {
    let had_deg = raw_tok.starts_with('°');
    let u = raw_tok.trim_start_matches('°').to_lowercase();
    match u.as_str() {
        "kb" | "kib" => Some(WinUnitFamily::DataBytes(1024.0, "KB")),
        "mb" | "mib" => Some(WinUnitFamily::DataBytes(1_048_576.0, "MB")),
        "gb" | "gib" => Some(WinUnitFamily::DataBytes(1_073_741_824.0, "GB")),
        "tb" | "tib" => Some(WinUnitFamily::DataBytes(1_099_511_627_776.0, "TB")),
        "byte" | "bytes" => Some(WinUnitFamily::DataBytes(1.0, "B")),
        "b" if explicit_syntax => Some(WinUnitFamily::DataBytes(1.0, "B")),

        "ms" | "msec" => Some(WinUnitFamily::DurationSec(0.001, "ms")),
        "sec" | "secs" | "second" | "seconds" | "秒" => Some(WinUnitFamily::DurationSec(1.0, "s")),
        "s" if explicit_syntax => Some(WinUnitFamily::DurationSec(1.0, "s")),
        "min" | "mins" | "minute" | "minutes" | "分钟" => {
            Some(WinUnitFamily::DurationSec(60.0, "min"))
        }
        "hr" | "hrs" | "hour" | "hours" | "小时" => Some(WinUnitFamily::DurationSec(3600.0, "h")),
        "h" if explicit_syntax => Some(WinUnitFamily::DurationSec(3600.0, "h")),
        "day" | "days" | "天" => Some(WinUnitFamily::DurationSec(86_400.0, "d")),
        "d" if explicit_syntax => Some(WinUnitFamily::DurationSec(86_400.0, "d")),

        "celsius" | "摄氏度" => Some(WinUnitFamily::TempC),
        "c" if had_deg || explicit_syntax => Some(WinUnitFamily::TempC),
        "fahrenheit" | "华氏度" => Some(WinUnitFamily::TempF),
        "f" if had_deg || explicit_syntax => Some(WinUnitFamily::TempF),

        "kg" | "kgs" | "千克" | "公斤" => Some(WinUnitFamily::MassKg(1.0, "kg")),
        "lb" | "lbs" | "pound" | "pounds" | "磅" => {
            Some(WinUnitFamily::MassKg(0.453_592_37, "lb"))
        }

        "cm" | "厘米" => Some(WinUnitFamily::LengthCm(1.0, "cm")),
        "inch" | "inches" | "英寸" => Some(WinUnitFamily::LengthCm(2.54, "in")),
        "in" if explicit_syntax => Some(WinUnitFamily::LengthCm(2.54, "in")),
        "km" | "公里" | "千米" => Some(WinUnitFamily::LengthCm(100_000.0, "km")),
        "mi" | "mile" | "miles" | "英里" => Some(WinUnitFamily::LengthCm(160_934.4, "mi")),
        _ => None,
    }
}

fn evaluate_unit_conversion(input: &str, has_leading_eq: bool) -> Option<InstantMathResult> {
    let cleaned = input.replace(',', "");
    static UNIT_RE: std::sync::OnceLock<regex_lite::Regex> = std::sync::OnceLock::new();
    let re = UNIT_RE.get_or_init(|| {
        regex_lite::Regex::new(
            r"(?i)^(-?\d+(?:\.\d+)?)\s*(°?[a-zA-Z\u4e00-\u9fa5]+)(?:\s*(?:to|in|->|=>|转)\s*(°?[a-zA-Z\u4e00-\u9fa5]+))?$",
        )
        .unwrap()
    });
    let caps = re.captures(&cleaned)?;
    let val: f64 = caps.get(1)?.as_str().parse().ok()?;
    if !val.is_finite() {
        return None;
    }
    let src_raw = caps.get(2)?.as_str();
    let dst_raw = caps.get(3).map(|m| m.as_str());
    let explicit = has_leading_eq || dst_raw.is_some() || cleaned.contains(' ');
    let src_unit = classify_unit_token(src_raw, explicit)?;
    let dst_unit = match dst_raw {
        Some(dt) => Some(classify_unit_token(dt, true)?),
        None => None,
    };

    let (out_val, out_lbl): (f64, &'static str) = match (src_unit, dst_unit) {
        (WinUnitFamily::TempC, None) | (WinUnitFamily::TempC, Some(WinUnitFamily::TempF)) => {
            if val < -273.15 {
                return None;
            }
            (val * 9.0 / 5.0 + 32.0, "°F")
        }
        (WinUnitFamily::TempF, None) | (WinUnitFamily::TempF, Some(WinUnitFamily::TempC)) => {
            if val < -459.67 {
                return None;
            }
            ((val - 32.0) * 5.0 / 9.0, "°C")
        }
        (WinUnitFamily::DataBytes(sf, sl), Some(WinUnitFamily::DataBytes(df, dl))) => {
            if val < 0.0 || sl == dl {
                return None;
            }
            ((val * sf) / df, dl)
        }
        (WinUnitFamily::DataBytes(sf, sl), None) => {
            if val < 0.0 {
                return None;
            }
            let bytes = val * sf;
            match sl {
                "B" => {
                    if bytes >= 1_073_741_824.0 {
                        (bytes / 1_073_741_824.0, "GB")
                    } else if bytes >= 1_048_576.0 {
                        (bytes / 1_048_576.0, "MB")
                    } else {
                        (bytes / 1024.0, "KB")
                    }
                }
                "KB" => {
                    if bytes >= 1_073_741_824.0 {
                        (bytes / 1_073_741_824.0, "GB")
                    } else {
                        (val / 1024.0, "MB")
                    }
                }
                "MB" => {
                    if val >= 1024.0 {
                        (val / 1024.0, "GB")
                    } else {
                        (val * 1024.0, "KB")
                    }
                }
                "GB" => {
                    if val >= 1024.0 {
                        (val / 1024.0, "TB")
                    } else {
                        (val * 1024.0, "MB")
                    }
                }
                _ => (val * 1024.0, "GB"),
            }
        }
        (WinUnitFamily::DurationSec(sf, sl), Some(WinUnitFamily::DurationSec(df, dl))) => {
            if val < 0.0 || sl == dl {
                return None;
            }
            ((val * sf) / df, dl)
        }
        (WinUnitFamily::DurationSec(sf, sl), None) => {
            if val < 0.0 {
                return None;
            }
            let secs = val * sf;
            match sl {
                "ms" => {
                    if secs >= 60.0 {
                        (secs / 60.0, "min")
                    } else {
                        (secs, "s")
                    }
                }
                "s" => {
                    if secs >= 86_400.0 {
                        (secs / 86_400.0, "d")
                    } else if secs >= 3600.0 {
                        (secs / 3600.0, "h")
                    } else {
                        (secs / 60.0, "min")
                    }
                }
                "min" => {
                    if secs >= 3600.0 {
                        (secs / 3600.0, "h")
                    } else {
                        (secs, "s")
                    }
                }
                "h" => {
                    if val >= 24.0 {
                        (val / 24.0, "d")
                    } else {
                        (val * 60.0, "min")
                    }
                }
                _ => (val * 24.0, "h"),
            }
        }
        (WinUnitFamily::MassKg(sf, sl), Some(WinUnitFamily::MassKg(df, dl))) => {
            if val < 0.0 || sl == dl {
                return None;
            }
            ((val * sf) / df, dl)
        }
        (WinUnitFamily::MassKg(sf, sl), None) => {
            if val < 0.0 {
                return None;
            }
            if sl == "kg" {
                (val / 0.453_592_37, "lb")
            } else {
                (val * sf, "kg")
            }
        }
        (WinUnitFamily::LengthCm(sf, sl), Some(WinUnitFamily::LengthCm(df, dl))) => {
            if val < 0.0 || sl == dl {
                return None;
            }
            ((val * sf) / df, dl)
        }
        (WinUnitFamily::LengthCm(sf, sl), None) => {
            if val < 0.0 {
                return None;
            }
            match sl {
                "in" => (val * sf, "cm"),
                "cm" => (val / 2.54, "in"),
                "mi" => ((val * sf) / 100_000.0, "km"),
                _ => ((val * sf) / 160_934.4, "mi"),
            }
        }
        _ => return None,
    };

    let rounded = (out_val * 10_000.0).round() / 10_000.0;
    let num_plain = format_clean_decimal(rounded);
    let plain_with_unit = format!("{num_plain} {out_lbl}");
    Some(InstantMathResult {
        expression_display: input.to_string(),
        plain_value: plain_with_unit,
        rmb_uppercase: None,
        used_clipboard_context: false,
    })
}

fn extract_leading_amount(clip: &str) -> Option<String> {
    let s = clip.trim();
    if s.is_empty() || s.len() > 48 || s.contains('\n') {
        return None;
    }
    let stripped = s
        .trim_start_matches(['¥', '￥', '$', '€', '£', ' '])
        .trim_end_matches(['元', '块', ' '])
        .replace(',', "");
    // 保护 11 位手机号与超长单号不被当成金额续算
    if stripped.len() >= 11 && stripped.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let mut multiplier = 1.0f64;
    let num_part = if let Some(p) = stripped.strip_suffix('亿') {
        multiplier = 100_000_000.0;
        p.trim()
    } else if let Some(p) = stripped.strip_suffix('万') {
        multiplier = 10_000.0;
        p.trim()
    } else {
        stripped.as_str()
    };
    let parsed: f64 = num_part.parse().ok()?;
    if !parsed.is_finite() {
        return None;
    }
    Some(format_clean_decimal(parsed * multiplier))
}

fn normalize_math_expr(raw: &str) -> Option<String> {
    let mut s = raw
        .replace('×', "*")
        .replace('÷', "/")
        .replace('（', "(")
        .replace('）', ")")
        .replace([',', '¥', '￥', '$', '元'], "");
    s = s.replace("亿", "*100000000").replace("万", "*10000");

    // 区分百分比 `13%` -> `*0.01` 与二元取模 `17 % 5`
    let chars: Vec<char> = s.chars().collect();
    let mut out = String::with_capacity(s.len() + 16);
    for i in 0..chars.len() {
        let c = chars[i];
        if c == '%' {
            let mut next_idx = i + 1;
            while next_idx < chars.len() && chars[next_idx].is_whitespace() {
                next_idx += 1;
            }
            let is_modulo = next_idx < chars.len()
                && (chars[next_idx].is_ascii_digit() || chars[next_idx] == '(');
            if is_modulo {
                out.push('%');
            } else {
                out.push_str("*0.01");
            }
        } else if c.is_ascii_digit() || matches!(c, '.' | '+' | '-' | '*' | '/' | '(' | ')' | ' ') {
            out.push(c);
        } else {
            return None;
        }
    }
    Some(out)
}

fn format_clean_decimal(val: f64) -> String {
    if (val - val.round()).abs() < 1e-9 && val.abs() < 1e15 {
        format!("{}", val.round() as i64)
    } else {
        let s = format!("{val:.6}");
        s.trim_end_matches('0').trim_end_matches('.').to_string()
    }
}

fn eval_expr(input: &str) -> Option<f64> {
    struct Parser<'a> {
        bytes: &'a [u8],
        pos: usize,
    }
    impl<'a> Parser<'a> {
        fn skip_ws(&mut self) {
            while self.pos < self.bytes.len() && self.bytes[self.pos].is_ascii_whitespace() {
                self.pos += 1;
            }
        }
        fn parse_add_sub(&mut self) -> Option<f64> {
            let mut val = self.parse_mul_div()?;
            loop {
                self.skip_ws();
                if self.pos >= self.bytes.len() {
                    break;
                }
                let op = self.bytes[self.pos];
                if op == b'+' || op == b'-' {
                    self.pos += 1;
                    let rhs = self.parse_mul_div()?;
                    val = if op == b'+' { val + rhs } else { val - rhs };
                } else {
                    break;
                }
            }
            Some(val)
        }
        fn parse_mul_div(&mut self) -> Option<f64> {
            let mut val = self.parse_unary()?;
            loop {
                self.skip_ws();
                if self.pos >= self.bytes.len() {
                    break;
                }
                let op = self.bytes[self.pos];
                if op == b'*' || op == b'/' || op == b'%' {
                    self.pos += 1;
                    let rhs = self.parse_unary()?;
                    if (op == b'/' || op == b'%') && rhs.abs() < 1e-12 {
                        return None;
                    }
                    val = match op {
                        b'*' => val * rhs,
                        b'/' => val / rhs,
                        _ => val % rhs,
                    };
                } else {
                    break;
                }
            }
            Some(val)
        }
        fn parse_unary(&mut self) -> Option<f64> {
            self.skip_ws();
            if self.pos < self.bytes.len() {
                if self.bytes[self.pos] == b'+' {
                    self.pos += 1;
                    return self.parse_unary();
                }
                if self.bytes[self.pos] == b'-' {
                    self.pos += 1;
                    return self.parse_unary().map(|v| -v);
                }
            }
            self.parse_primary()
        }
        fn parse_primary(&mut self) -> Option<f64> {
            self.skip_ws();
            if self.pos >= self.bytes.len() {
                return None;
            }
            if self.bytes[self.pos] == b'(' {
                self.pos += 1;
                let v = self.parse_add_sub()?;
                self.skip_ws();
                if self.pos >= self.bytes.len() || self.bytes[self.pos] != b')' {
                    return None;
                }
                self.pos += 1;
                return Some(v);
            }
            let start = self.pos;
            while self.pos < self.bytes.len()
                && (self.bytes[self.pos].is_ascii_digit() || self.bytes[self.pos] == b'.')
            {
                self.pos += 1;
            }
            if self.pos == start {
                return None;
            }
            std::str::from_utf8(&self.bytes[start..self.pos])
                .ok()?
                .parse::<f64>()
                .ok()
        }
    }

    let mut p = Parser {
        bytes: input.as_bytes(),
        pos: 0,
    };
    let res = p.parse_add_sub()?;
    p.skip_ws();
    if p.pos == p.bytes.len() {
        Some(res)
    } else {
        None
    }
}

/// 一行闪念速记与待办解析器（支持 `[] 事项`、`- 事项`、`+待办 事项`、`todo: 事项`、`> 备注名 :: 正文`）
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuickCaptureIntent {
    pub alias: Option<String>,
    pub body: String,
    pub default_pin: bool,
    pub default_todo: bool,
}

pub fn parse_quick_capture(query: &str) -> Option<QuickCaptureIntent> {
    let trimmed = query.trim_start_matches([' ', '\t']);
    if trimmed.is_empty() {
        return None;
    }

    if let Some(todo_rest) = extract_todo_capture_payload(trimmed) {
        let (alias, body) = split_alias_and_body(todo_rest);
        return Some(QuickCaptureIntent {
            alias,
            body,
            default_pin: false,
            default_todo: true,
        });
    }

    let trimmed = trimmed.trim();
    let (rest, force_pin) = if let Some(r) = trimmed.strip_prefix(">>") {
        (r.trim(), true)
    } else if let Some(r) = trimmed.strip_prefix('>') {
        // 防误伤 `>= 100`
        if r.starts_with('=') {
            return None;
        }
        (r.trim(), false)
    } else if let Some(r) = trimmed.strip_prefix("+收藏 ") {
        (r.trim(), true)
    } else {
        return None;
    };

    if rest.is_empty() {
        return Some(QuickCaptureIntent {
            alias: None,
            body: String::new(),
            default_pin: force_pin,
            default_todo: false,
        });
    }

    let (alias, body) = split_alias_and_body(rest);
    if alias.is_some() {
        Some(QuickCaptureIntent {
            alias,
            body,
            default_pin: true,
            default_todo: false,
        })
    } else {
        let is_tpl = body.contains("{{") && body.contains("}}");
        Some(QuickCaptureIntent {
            alias: None,
            body,
            default_pin: force_pin || is_tpl,
            default_todo: false,
        })
    }
}

pub fn split_alias_and_body(text: &str) -> (Option<String>, String) {
    for sep in ["::", "：："] {
        if let Some((left, right)) = text.split_once(sep) {
            let l = left.trim();
            let r = right.trim();
            if !l.is_empty() && !r.is_empty() {
                return (Some(l.to_string()), r.to_string());
            }
        }
    }
    (None, text.trim().to_string())
}

fn extract_todo_capture_payload(s: &str) -> Option<&str> {
    for marker in ["- [ ]", "* [ ]", "[ ]", "[]", "【 】", "【】"] {
        if s.trim_end() == marker {
            return Some("");
        }
        if let Some(rest) = s.strip_prefix(marker) {
            if rest.starts_with(' ') || rest.starts_with('\t') || marker == "[]" || marker == "【】"
            {
                return Some(rest.trim());
            }
        }
    }
    let lower = s.to_lowercase();
    for p in ["+待办", "@加待办", "@新建待办", "+todo"] {
        if lower.starts_with(p) {
            let rest = &s[p.len()..];
            if rest.trim().is_empty() {
                return Some("");
            }
            if rest.starts_with(' ') || rest.starts_with('\t') {
                return Some(rest.trim());
            }
        }
    }
    for p in ["todo:", "todo：", "待办:", "待办："] {
        if lower.starts_with(p) {
            return Some(s[p.len()..].trim());
        }
    }
    if let Some(rest) = s.strip_prefix("- ").or_else(|| s.strip_prefix("－ ")) {
        let clean = rest.trim();
        if clean.is_empty() {
            return Some("");
        }
        if let Some(ch) = clean.chars().next() {
            if !ch.is_ascii_digit() && !matches!(ch, '.' | '(' | '-' | '+') {
                return Some(clean);
            }
        }
    }
    None
}

/// 从多行剪贴文本中拆解可独立勾选的待办事项（自动跳过已完成 `[x]` 项，排除代码与纯金额账单）
pub fn extract_checklist_items(raw_text: &str) -> Vec<String> {
    if raw_text.len() > 16_384 {
        return Vec::new();
    }
    let lines: Vec<&str> = raw_text
        .lines()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty())
        .collect();
    if lines.len() < 2 || lines.len() > 30 {
        return Vec::new();
    }

    let unchecked = [
        "- [ ]", "* [ ]", "+ [ ]", "[ ]", "[]", "【 】", "【】", "□", "☐",
    ];
    let checked = [
        "- [x]", "- [X]", "* [x]", "* [X]", "[x]", "[X]", "☑", "✅", "✓",
    ];

    let mut explicit_unchecked = Vec::new();
    let mut explicit_total = 0usize;
    for &line in &lines {
        if checked.iter().any(|m| line.starts_with(m)) {
            explicit_total += 1;
            continue;
        }
        if let Some(marker) = unchecked.iter().find(|&&m| line.starts_with(m)) {
            let body = line[marker.len()..].trim();
            if !body.is_empty() {
                explicit_total += 1;
                if !explicit_unchecked.iter().any(|x| x == body) {
                    explicit_unchecked.push(body.to_string());
                }
            }
        }
    }
    if explicit_total >= 2 && explicit_unchecked.len() >= 2 {
        return explicit_unchecked;
    }

    if lines.len() > 20 || (raw_text.contains('{') && raw_text.contains('}')) {
        return Vec::new();
    }
    for noise in [
        "func ", "fn ", "struct ", "class ", "import ", "SELECT ", "INSERT ", "curl ",
    ] {
        if raw_text.contains(noise) {
            return Vec::new();
        }
    }

    let mut bullets = Vec::new();
    for &line in &lines {
        let Some(body) = strip_bullet_or_num_prefix(line) else {
            return Vec::new();
        };
        let char_cnt = body.chars().count();
        if !(2..=120).contains(&char_cnt)
            || !body
                .chars()
                .any(|c| c.is_ascii_alphabetic() || ('\u{4E00}'..='\u{9FFF}').contains(&c))
        {
            return Vec::new();
        }
        if !bullets.iter().any(|x| x == body) {
            bullets.push(body.to_string());
        }
    }
    if bullets.len() >= 2 {
        bullets
    } else {
        Vec::new()
    }
}

fn strip_bullet_or_num_prefix(line: &str) -> Option<&str> {
    for b in ["- ", "* ", "• ", "· "] {
        if let Some(r) = line.strip_prefix(b) {
            let t = r.trim();
            return if t.is_empty() { None } else { Some(t) };
        }
    }
    let digit_bytes = line.bytes().take_while(|b| b.is_ascii_digit()).count();
    if (1..=3).contains(&digit_bytes) {
        let rest_after_num = &line[digit_bytes..];
        for sep in [".", "、", ")", "）"] {
            if let Some(after_sep) = rest_after_num.strip_prefix(sep) {
                let t = after_sep.trim();
                if t.is_empty() {
                    return None;
                }
                if sep == "."
                    && t.bytes()
                        .next()
                        .map(|b| b.is_ascii_digit())
                        .unwrap_or(false)
                {
                    return None;
                }
                return Some(t);
            }
        }
    }
    None
}

/// 提取 `@建议 ...` / `@suggest ...` 自然语言偏好指令
pub fn extract_suggestion_payload(query: &str) -> Option<String> {
    let trimmed = query.trim();
    for prefix in ["@建议", "@反馈", "@进化", "@suggest"] {
        if let Some(rest) = trimmed.strip_prefix(prefix) {
            return Some(rest.trim().to_string());
        }
    }
    None
}

// ============================================================================
// 4. 原位剪贴行级差异比对（有界 LCS + 压缩/乱序 JSON 字典序语义对齐）
// ============================================================================

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiffLineKind {
    Unchanged,
    Added,
    Removed,
    Collapsed(usize),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiffLine {
    pub kind: DiffLineKind,
    pub text: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClipboardDiffSummary {
    pub added_count: usize,
    pub removed_count: usize,
    pub json_semantically_equal: bool,
    pub lines: Vec<DiffLine>,
}

impl ClipboardDiffSummary {
    pub fn badge_title(&self) -> String {
        if self.added_count == 0 && self.removed_count == 0 {
            if self.json_semantically_equal {
                "JSON 语义一致".to_string()
            } else {
                "内容完全一致".to_string()
            }
        } else {
            format!("+{} / -{} 差异", self.added_count, self.removed_count)
        }
    }
}

pub fn compute_clipboard_diff(older: &str, newer: &str) -> ClipboardDiffSummary {
    let clamped_old = crate::model::safe_utf8_prefix(older, 262_144);
    let clamped_new = crate::model::safe_utf8_prefix(newer, 262_144);
    let (norm_old, norm_new, both_json) =
        match (canonical_pretty_json(clamped_old), canonical_pretty_json(clamped_new)) {
            (Some(o), Some(n)) => (o, n, true),
            _ => (
                clamped_old.replace("\r\n", "\n"),
                clamped_new.replace("\r\n", "\n"),
                false,
            ),
        };

    if norm_old == norm_new {
        return ClipboardDiffSummary {
            added_count: 0,
            removed_count: 0,
            json_semantically_equal: both_json && older.trim() != newer.trim(),
            lines: vec![DiffLine {
                kind: DiffLineKind::Unchanged,
                text: if both_json {
                    "两段 JSON 键值语义 100% 一致（仅空白或字段顺序不同）".to_string()
                } else {
                    "两段文本完全一致，无行级差异".to_string()
                },
            }],
        };
    }

    let old_lines: Vec<&str> = norm_old.lines().take(180).collect();
    let new_lines: Vec<&str> = norm_new.lines().take(180).collect();
    let m = old_lines.len();
    let n = new_lines.len();

    let mut dp = vec![vec![0u16; n + 1]; m + 1];
    for i in (0..m).rev() {
        for j in (0..n).rev() {
            if old_lines[i] == new_lines[j] {
                dp[i][j] = dp[i + 1][j + 1] + 1;
            } else {
                dp[i][j] = dp[i + 1][j].max(dp[i][j + 1]);
            }
        }
    }

    let mut raw_diff: Vec<DiffLine> = Vec::with_capacity(m + n);
    let (mut i, mut j) = (0, 0);
    let (mut added, mut removed) = (0usize, 0usize);

    while i < m && j < n {
        if old_lines[i] == new_lines[j] {
            raw_diff.push(DiffLine {
                kind: DiffLineKind::Unchanged,
                text: format!("  {}", old_lines[i]),
            });
            i += 1;
            j += 1;
        } else if dp[i + 1][j] >= dp[i][j + 1] {
            removed += 1;
            raw_diff.push(DiffLine {
                kind: DiffLineKind::Removed,
                text: format!("- {}", old_lines[i]),
            });
            i += 1;
        } else {
            added += 1;
            raw_diff.push(DiffLine {
                kind: DiffLineKind::Added,
                text: format!("+ {}", new_lines[j]),
            });
            j += 1;
        }
    }
    while i < m {
        removed += 1;
        raw_diff.push(DiffLine {
            kind: DiffLineKind::Removed,
            text: format!("- {}", old_lines[i]),
        });
        i += 1;
    }
    while j < n {
        added += 1;
        raw_diff.push(DiffLine {
            kind: DiffLineKind::Added,
            text: format!("+ {}", new_lines[j]),
        });
        j += 1;
    }

    // 折叠连续 > 4 行的相同上下文行
    let mut compact = Vec::new();
    let mut run_start = 0;
    while run_start < raw_diff.len() {
        if raw_diff[run_start].kind != DiffLineKind::Unchanged {
            compact.push(raw_diff[run_start].clone());
            run_start += 1;
            continue;
        }
        let mut run_end = run_start;
        while run_end < raw_diff.len() && raw_diff[run_end].kind == DiffLineKind::Unchanged {
            run_end += 1;
        }
        let count = run_end - run_start;
        if count > 5 {
            compact.push(raw_diff[run_start].clone());
            compact.push(DiffLine {
                kind: DiffLineKind::Collapsed(count - 2),
                text: format!("  ··· 已折叠 {} 行相同上下文 ···", count - 2),
            });
            compact.push(raw_diff[run_end - 1].clone());
        } else {
            for item in &raw_diff[run_start..run_end] {
                compact.push(item.clone());
            }
        }
        run_start = run_end;
    }

    ClipboardDiffSummary {
        added_count: added,
        removed_count: removed,
        json_semantically_equal: false,
        lines: compact,
    }
}

fn canonical_pretty_json(raw: &str) -> Option<String> {
    let t = raw.trim();
    if t.len() > 131_072
        || !((t.starts_with('{') && t.ends_with('}')) || (t.starts_with('[') && t.ends_with(']')))
    {
        return None;
    }
    let val: serde_json::Value = serde_json::from_str(t).ok()?;
    let sorted = sort_json_value(val, 0)?;
    serde_json::to_string_pretty(&sorted).ok()
}

fn sort_json_value(v: serde_json::Value, depth: usize) -> Option<serde_json::Value> {
    if depth > 32 {
        return None;
    }
    match v {
        serde_json::Value::Object(map) => {
            let mut entries: Vec<(String, serde_json::Value)> = map.into_iter().collect();
            entries.sort_by(|a, b| a.0.cmp(&b.0));
            let mut out = serde_json::Map::new();
            for (k, child) in entries {
                out.insert(k, sort_json_value(child, depth + 1)?);
            }
            Some(serde_json::Value::Object(out))
        }
        serde_json::Value::Array(arr) => {
            let mut sorted_arr = Vec::with_capacity(arr.len());
            for item in arr {
                sorted_arr.push(sort_json_value(item, depth + 1)?);
            }
            Some(serde_json::Value::Array(sorted_arr))
        }
        other => Some(other),
    }
}

/// 相对时间友好展示（对齐 macOS 卡片右下角：刚刚 / 3 分钟前 / 2 小时前 / 3 天前）
pub fn format_relative_time(item_secs: u64) -> String {
    let now = now_unix_secs();
    let diff = now.saturating_sub(item_secs);
    if diff < 45 {
        "刚刚".to_string()
    } else if diff < 3_600 {
        format!("{} 分钟前", diff / 60)
    } else if diff < 86_400 {
        format!("{} 小时前", diff / 3_600)
    } else {
        format!("{} 天前", diff / 86_400)
    }
}

// ============================================================================
// 8. 最小够用结构化净提与收件名片一键拆入连填引擎（SmartFieldExtractor）
// ============================================================================

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShippingContact {
    pub recipient_name: Option<String>,
    pub clean_phone: String,
    pub clean_address: String,
}

impl ShippingContact {
    pub fn clean_card_text(&self) -> String {
        if let Some(name) = &self.recipient_name {
            if !name.is_empty() {
                return format!("{name}\n{}\n{}", self.clean_phone, self.clean_address);
            }
        }
        format!("{}\n{}", self.clean_phone, self.clean_address)
    }

    pub fn queue_fields(&self) -> Vec<String> {
        if let Some(name) = &self.recipient_name {
            if !name.is_empty() {
                return vec![
                    name.clone(),
                    self.clean_phone.clone(),
                    self.clean_address.clone(),
                ];
            }
        }
        vec![self.clean_phone.clone(), self.clean_address.clone()]
    }
}

pub fn has_chinese_address(raw: &str) -> bool {
    let sample = crate::model::safe_utf8_prefix(raw, 2048);
    if sample.contains("收货地址") || sample.contains("收件地址") || sample.contains("详细地址")
    {
        return true;
    }
    const REGIONS: &[&str] = &["省", "市", "自治区", "特别行政区", "区", "县", "旗"];
    const STREETS: &[&str] = &[
        "路", "街", "道", "巷", "号", "弄", "室", "楼", "层", "栋", "幢", "单元", "大厦", "广场",
        "中心", "园", "苑", "小区", "村", "镇",
    ];
    REGIONS.iter().any(|r| sample.contains(r)) && STREETS.iter().any(|s| sample.contains(s))
}

pub fn has_mainland_phone(raw: &str) -> bool {
    if !raw.contains('1') {
        return false;
    }
    let sample = crate::model::safe_utf8_prefix(raw, 2048);
    static PHONE_FMT_RE: std::sync::OnceLock<regex_lite::Regex> = std::sync::OnceLock::new();
    let re = PHONE_FMT_RE.get_or_init(|| {
        regex_lite::Regex::new(r"(?:\+?86[\s-]*)?(1[3-9]\d[\s-]?\d{4}[\s-]?\d{4})").unwrap()
    });
    for m in re.find_iter(sample) {
        let prev_alnum = m.start() > 0 && sample.as_bytes()[m.start() - 1].is_ascii_alphanumeric();
        let next_alnum =
            m.end() < sample.len() && sample.as_bytes()[m.end()].is_ascii_alphanumeric();
        if !prev_alnum && !next_alnum {
            return true;
        }
    }
    false
}

pub fn has_email_address(raw: &str) -> bool {
    if !raw.contains('@') {
        return false;
    }
    let sample = crate::model::safe_utf8_prefix(raw, 2048);
    static EMAIL_RE: std::sync::OnceLock<regex_lite::Regex> = std::sync::OnceLock::new();
    let re = EMAIL_RE.get_or_init(|| {
        regex_lite::Regex::new(r"\b[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]+\.[A-Za-z]{2,18}\b")
            .unwrap()
    });
    re.is_match(sample)
}

pub fn has_ipv4_address(raw: &str) -> bool {
    if !raw.contains('.') {
        return false;
    }
    let sample = crate::model::safe_utf8_prefix(raw, 2048);
    static IPV4_RE: std::sync::OnceLock<regex_lite::Regex> = std::sync::OnceLock::new();
    let re = IPV4_RE.get_or_init(|| {
        regex_lite::Regex::new(
            r"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b",
        )
        .unwrap()
    });
    re.is_match(sample)
}

pub fn extract_normalized_single_phone(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.len() < 11 || trimmed.len() > 240 {
        return None;
    }
    static PHONE_FMT_RE: std::sync::OnceLock<regex_lite::Regex> = std::sync::OnceLock::new();
    let re = PHONE_FMT_RE.get_or_init(|| {
        regex_lite::Regex::new(r"(?:\+?86[\s-]*)?(1[3-9]\d[\s-]?\d{4}[\s-]?\d{4})").unwrap()
    });
    let mut found: Option<String> = None;
    for caps in re.captures_iter(trimmed) {
        let m0 = caps.get(0)?;
        let prev_alnum =
            m0.start() > 0 && trimmed.as_bytes()[m0.start() - 1].is_ascii_alphanumeric();
        let next_alnum =
            m0.end() < trimmed.len() && trimmed.as_bytes()[m0.end()].is_ascii_alphanumeric();
        if prev_alnum || next_alnum {
            continue;
        }
        if found.is_some() {
            return None;
        }
        let g1 = caps.get(1)?.as_str();
        let digits: String = g1.chars().filter(|c| c.is_ascii_digit()).collect();
        if digits.len() == 11 {
            found = Some(digits);
        }
    }
    let digits = found?;
    if digits == trimmed {
        return None;
    }
    Some(digits)
}

pub fn extract_unique_emails(raw: &str) -> Vec<String> {
    if !raw.contains('@') || raw.len() > 32_768 {
        return Vec::new();
    }
    static EMAIL_RE: std::sync::OnceLock<regex_lite::Regex> = std::sync::OnceLock::new();
    let re = EMAIL_RE.get_or_init(|| {
        regex_lite::Regex::new(r"\b[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]+\.[A-Za-z]{2,18}\b")
            .unwrap()
    });
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for m in re.find_iter(raw) {
        let mail = m.as_str();
        if seen.insert(mail.to_ascii_lowercase()) {
            out.push(mail.to_string());
        }
    }
    if out.len() >= 2 {
        out
    } else {
        Vec::new()
    }
}

pub fn extract_unique_ipv4s(raw: &str) -> Vec<String> {
    if !raw.contains('.') || raw.len() > 32_768 {
        return Vec::new();
    }
    static IPV4_RE: std::sync::OnceLock<regex_lite::Regex> = std::sync::OnceLock::new();
    let re = IPV4_RE.get_or_init(|| {
        regex_lite::Regex::new(
            r"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b",
        )
        .unwrap()
    });
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for m in re.find_iter(raw) {
        let ip = m.as_str();
        if seen.insert(ip.to_string()) {
            out.push(ip.to_string());
        }
    }
    if out.len() >= 2 {
        out
    } else {
        Vec::new()
    }
}

/// 从群聊通知、日报或参考资料段落中批量提取全部 HTTP(S) 链接，自动剥除营销追踪尾巴并按出现顺序去重（>= 2 条不同链接时触发）
pub fn extract_unique_clean_urls(raw: &str) -> Vec<String> {
    if raw.len() > 32_768 {
        return Vec::new();
    }
    let trimmed = raw.trim();
    let lower = trimmed.to_ascii_lowercase();
    if (!lower.contains("http://") && !lower.contains("https://"))
        || lower.starts_with("curl ")
        || lower.starts_with("curl\t")
        || trimmed.starts_with('|')
    {
        return Vec::new();
    }
    static MULTI_URL_RE: std::sync::OnceLock<regex_lite::Regex> = std::sync::OnceLock::new();
    let re = MULTI_URL_RE.get_or_init(|| {
        regex_lite::Regex::new(r#"https?://[^\s<>"'()（）【】\[\]，。；！、`|]+"#).unwrap()
    });
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for m in re.find_iter(raw) {
        let candidate = m
            .as_str()
            .trim_end_matches(&['.', ',', ';', ':', '!', '?', ')', '\'', ']', '}', '>'][..]);
        if candidate.len() < 10 {
            continue;
        }
        let cleaned =
            crate::engines::clean_tracking_url(candidate).unwrap_or_else(|| candidate.to_string());
        if seen.insert(cleaned.clone()) {
            out.push(cleaned);
        }
    }
    if out.len() >= 2 {
        out
    } else {
        Vec::new()
    }
}

pub fn parse_shipping_contact(raw: &str) -> Option<ShippingContact> {
    let trimmed = raw.trim();
    if trimmed.chars().count() < 14 || trimmed.len() > 1_200 {
        return None;
    }
    let lower = trimmed.to_ascii_lowercase();
    if trimmed.starts_with('{') || trimmed.starts_with('|') || lower.starts_with("curl ") {
        return None;
    }
    if trimmed.lines().count() > 8 || !has_chinese_address(trimmed) {
        return None;
    }

    static URL_STRIP_RE: std::sync::OnceLock<regex_lite::Regex> = std::sync::OnceLock::new();
    static REMARK_RE: std::sync::OnceLock<regex_lite::Regex> = std::sync::OnceLock::new();
    static PHONE_FMT_RE: std::sync::OnceLock<regex_lite::Regex> = std::sync::OnceLock::new();
    static POLITE_RE: std::sync::OnceLock<regex_lite::Regex> = std::sync::OnceLock::new();
    static LABEL_RE: std::sync::OnceLock<regex_lite::Regex> = std::sync::OnceLock::new();

    let url_re =
        URL_STRIP_RE.get_or_init(|| regex_lite::Regex::new(r"https?://[^\s，,）)]+").unwrap());
    let remark_re = REMARK_RE.get_or_init(|| {
        regex_lite::Regex::new(
            r"[（(][^）)\n]{0,24}(?:顺丰|到付|寄付|包邮|圆通|中通|韵达|申通|极兔|京东|快递|勿电|丰巢|谢谢|麻烦|加急)[^）)\n]{0,24}[）)]",
        )
        .unwrap()
    });
    let phone_re = PHONE_FMT_RE.get_or_init(|| {
        regex_lite::Regex::new(r"(?:\+?86[\s-]*)?(1[3-9]\d[\s-]?\d{4}[\s-]?\d{4})").unwrap()
    });
    let polite_re = POLITE_RE.get_or_init(|| {
        regex_lite::Regex::new(
            r"^(?:亲|你好|您好|麻烦|帮我|请)?(?:帮我)?(?:发|寄)?(?:一下|个)?(?:顺丰|快递|样品|包裹)?\s*[:：，,\s]+",
        )
        .unwrap()
    });
    let label_re = LABEL_RE.get_or_init(|| {
        regex_lite::Regex::new(
            r"(?:收件人|收货人|联系人|姓名|联系电话|手机号码|手机号|电话|手机|收货地址|详细地址|寄件地址|收件地址|地址)\s*[:：]\s*",
        )
        .unwrap()
    });

    let mut working = url_re.replace_all(trimmed, " ").into_owned();
    working = remark_re.replace_all(&working, " ").into_owned();

    let mut matched_span: Option<(usize, usize, String)> = None;
    for caps in phone_re.captures_iter(&working) {
        let Some(m0) = caps.get(0) else { continue };
        let prev_alnum =
            m0.start() > 0 && working.as_bytes()[m0.start() - 1].is_ascii_alphanumeric();
        let next_alnum =
            m0.end() < working.len() && working.as_bytes()[m0.end()].is_ascii_alphanumeric();
        if prev_alnum || next_alnum {
            continue;
        }
        let Some(g1) = caps.get(1) else { continue };
        let digits: String = g1.as_str().chars().filter(|c| c.is_ascii_digit()).collect();
        if digits.len() == 11 {
            matched_span = Some((m0.start(), m0.end(), digits));
            break;
        }
    }
    let (p_start, p_end, clean_phone) = matched_span?;
    working.replace_range(p_start..p_end, "\n");
    working = polite_re.replace(&working, "").into_owned();
    working = label_re.replace_all(&working, "\n").into_owned();

    let mut tokens: Vec<String> = Vec::new();
    for seg in working.split(['\n', ',', '，', ';', '；', '|']) {
        let s = seg.trim();
        if s.is_empty() {
            continue;
        }
        if has_chinese_address(s) && s.contains(' ') {
            let parts: Vec<&str> = s.split_whitespace().collect();
            if parts.len() >= 2 {
                let first_len = parts[0].chars().count();
                if (2..=6).contains(&first_len) && !has_chinese_address(parts[0]) {
                    tokens.push(parts[0].to_string());
                    tokens.push(parts[1..].join(""));
                    continue;
                }
            }
        }
        tokens.push(s.to_string());
    }

    let mut found_addr: Option<String> = None;
    let mut found_name: Option<String> = None;
    for tok in tokens {
        let c = tok
            .trim_matches(['：', ':', '，', ',', '。', '.', '、', '-', '—', ' '])
            .to_string();
        if c.is_empty() {
            continue;
        }
        let ch_cnt = c.chars().count();
        if found_addr.is_none() && (has_chinese_address(&c) || ch_cnt >= 9) {
            found_addr = Some(c);
        } else if found_name.is_none()
            && (2..=12).contains(&ch_cnt)
            && !c.chars().all(|ch| ch.is_ascii_digit())
        {
            found_name = Some(c);
        }
    }

    let clean_address = found_addr.filter(|a| a.chars().count() >= 6)?;
    Some(ShippingContact {
        recipient_name: found_name,
        clean_phone,
        clean_address,
    })
}

// ============================================================================
// 13. 锤子大爆炸（Big Bang）跨端对齐智能分词与选区组装引擎
// ============================================================================

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BigBangGranularity {
    Word,
    Char,
    Line,
}

impl BigBangGranularity {
    pub fn title(self) -> &'static str {
        match self {
            BigBangGranularity::Word => "按词",
            BigBangGranularity::Char => "按字",
            BigBangGranularity::Line => "按行",
        }
    }

    pub fn next(self) -> Self {
        match self {
            BigBangGranularity::Word => BigBangGranularity::Char,
            BigBangGranularity::Char => BigBangGranularity::Line,
            BigBangGranularity::Line => BigBangGranularity::Word,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BigBangToken {
    pub id: usize,
    pub text: String,
    pub line_index: usize,
    pub is_line_break: bool,
    pub byte_start: usize,
    pub byte_end: usize,
    pub granularity: BigBangGranularity,
}

fn is_big_bang_ascii_word_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '_' | '/')
}

fn is_big_bang_ascii_boundary_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || matches!(b, b'_' | b'/')
}

fn is_cjk_char(c: char) -> bool {
    ('\u{4E00}'..='\u{9FFF}').contains(&c)
        || ('\u{3400}'..='\u{4DBF}').contains(&c)
        || ('\u{3040}'..='\u{30FF}').contains(&c)
}

fn big_bang_protected_spans(line: &str) -> Vec<(usize, usize)> {
    static ENTITY_RE: std::sync::OnceLock<regex_lite::Regex> = std::sync::OnceLock::new();
    let re = ENTITY_RE.get_or_init(|| {
        regex_lite::Regex::new(
            r#"https?://[^\s\x{4E00}-\x{9FFF}\x{3000}-\x{303F}\x{FF00}-\x{FFEF}<>"'`()\[\]{}（）【】]+|[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}|\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b|\b(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?\b|1[3-9]\d(?:[- ]?\d{4}){2}|\b[A-Za-z0-9]+(?:[_\-.][A-Za-z0-9]+)+\b"#,
        )
        .unwrap()
    });
    let bytes = line.as_bytes();
    let mut out = Vec::new();
    let mut last_end = 0usize;
    for m in re.find_iter(line) {
        if m.start() < last_end {
            continue;
        }
        let raw_slice = &line[m.start()..m.end()];
        // 手机号子支（regex_lite 不支持零宽断言，手动检验前后数字边界防 13+ 位长整数被误裁）
        if raw_slice.starts_with('1')
            && !raw_slice.starts_with("http")
            && !raw_slice.contains('@')
            && !raw_slice.contains('.')
            && raw_slice.chars().all(|c| c.is_ascii_digit() || c == '-' || c == ' ')
        {
            let prev_digit = m.start() > 0 && bytes[m.start() - 1].is_ascii_digit();
            let next_digit = m.end() < bytes.len() && bytes[m.end()].is_ascii_digit();
            if prev_digit || next_digit {
                continue;
            }
        }
        let mut end = m.end();
        if raw_slice.starts_with("http") {
            while end > m.start() {
                let Some(ch) = line[m.start()..end].chars().next_back() else {
                    break;
                };
                if matches!(
                    ch,
                    '.' | ',' | ';' | ':' | '!' | '?' | '。' | '，' | '；' | '：' | '！' | '？' | '）' | ')' | ']' | '}' | '"'
                ) {
                    end -= ch.len_utf8();
                } else {
                    break;
                }
            }
        }
        if end > m.start() {
            out.push((m.start(), end));
            last_end = end;
        }
    }
    out
}

fn push_word_segment_tokens(
    seg: &str,
    seg_offset: usize,
    line_index: usize,
    next_id: &mut usize,
    out: &mut Vec<BigBangToken>,
) {
    let mut chars = seg.char_indices().peekable();
    while let Some((idx, ch)) = chars.peek().copied() {
        if ch.is_whitespace() {
            chars.next();
            continue;
        }
        if is_cjk_char(ch) {
            let mut end = idx + ch.len_utf8();
            chars.next();
            // 双字常见词平滑聚合或按单字可点击：单汉字保证 Windows 无外置词典下任意中文词组都能精确切选
            while let Some(&(_, next_ch)) = chars.peek() {
                if next_ch == 'ー' {
                    end += next_ch.len_utf8();
                    chars.next();
                } else {
                    break;
                }
            }
            out.push(BigBangToken {
                id: *next_id,
                text: seg[idx..end].to_string(),
                line_index,
                is_line_break: false,
                byte_start: seg_offset + idx,
                byte_end: seg_offset + end,
                granularity: BigBangGranularity::Word,
            });
            *next_id += 1;
            continue;
        }
        if is_big_bang_ascii_word_char(ch) || ch.is_alphanumeric() {
            let start = idx;
            let mut end = idx + ch.len_utf8();
            chars.next();
            while let Some(&(nidx, nch)) = chars.peek() {
                if !nch.is_whitespace()
                    && !is_cjk_char(nch)
                    && (is_big_bang_ascii_word_char(nch) || nch.is_alphanumeric())
                {
                    end = nidx + nch.len_utf8();
                    chars.next();
                } else {
                    break;
                }
            }
            out.push(BigBangToken {
                id: *next_id,
                text: seg[start..end].to_string(),
                line_index,
                is_line_break: false,
                byte_start: seg_offset + start,
                byte_end: seg_offset + end,
                granularity: BigBangGranularity::Word,
            });
            *next_id += 1;
            continue;
        }
        chars.next();
    }
}

pub fn tokenize_big_bang(text: &str, granularity: BigBangGranularity) -> Vec<BigBangToken> {
    if text.is_empty() {
        return Vec::new();
    }
    let normalized = text.replace("\r\n", "\n").replace('\r', "\n");
    let mut result = Vec::new();
    let mut next_id = 0usize;

    for (line_idx, raw_line) in normalized.split('\n').enumerate() {
        if line_idx > 0 && granularity != BigBangGranularity::Line {
            result.push(BigBangToken {
                id: next_id,
                text: "\n".to_string(),
                line_index: line_idx,
                is_line_break: true,
                byte_start: 0,
                byte_end: 0,
                granularity,
            });
            next_id += 1;
        }

        let trimmed = raw_line.trim();
        if trimmed.is_empty() {
            continue;
        }

        match granularity {
            BigBangGranularity::Line => {
                result.push(BigBangToken {
                    id: next_id,
                    text: trimmed.to_string(),
                    line_index: line_idx,
                    is_line_break: false,
                    byte_start: 0,
                    byte_end: trimmed.len(),
                    granularity,
                });
                next_id += 1;
            }
            BigBangGranularity::Char => {
                for (bidx, ch) in raw_line.char_indices() {
                    if !ch.is_whitespace() {
                        result.push(BigBangToken {
                            id: next_id,
                            text: ch.to_string(),
                            line_index: line_idx,
                            is_line_break: false,
                            byte_start: bidx,
                            byte_end: bidx + ch.len_utf8(),
                            granularity,
                        });
                        next_id += 1;
                    }
                }
            }
            BigBangGranularity::Word => {
                let spans = big_bang_protected_spans(raw_line);
                let mut cursor = 0usize;
                for (s, e) in spans {
                    if cursor < s {
                        push_word_segment_tokens(
                            &raw_line[cursor..s],
                            cursor,
                            line_idx,
                            &mut next_id,
                            &mut result,
                        );
                    }
                    result.push(BigBangToken {
                        id: next_id,
                        text: raw_line[s..e].to_string(),
                        line_index: line_idx,
                        is_line_break: false,
                        byte_start: s,
                        byte_end: e,
                        granularity,
                    });
                    next_id += 1;
                    cursor = e;
                }
                if cursor < raw_line.len() {
                    push_word_segment_tokens(
                        &raw_line[cursor..],
                        cursor,
                        line_idx,
                        &mut next_id,
                        &mut result,
                    );
                }
            }
        }
    }
    result
}

pub fn assemble_big_bang_selection(
    tokens: &[BigBangToken],
    selected_ids: &std::collections::HashSet<usize>,
) -> String {
    let picked: Vec<&BigBangToken> = tokens
        .iter()
        .filter(|t| !t.is_line_break && selected_ids.contains(&t.id))
        .collect();
    let Some(first) = picked.first() else {
        return String::new();
    };

    let mut out = first.text.clone();
    let mut prev = *first;

    for cur in picked.into_iter().skip(1) {
        if cur.line_index > prev.line_index {
            out.push('\n');
        } else {
            let adj_char = cur.granularity == BigBangGranularity::Char
                && prev.granularity == BigBangGranularity::Char
                && cur.byte_start == prev.byte_end;
            if !adj_char {
                if let (Some(&lb), Some(&fb)) = (prev.text.as_bytes().last(), cur.text.as_bytes().first())
                {
                    if is_big_bang_ascii_boundary_byte(lb) && is_big_bang_ascii_boundary_byte(fb) {
                        out.push(' ');
                    }
                }
            }
        }
        out.push_str(&cur.text);
        prev = cur;
    }
    out
}

/// 判断主列表按下普通空格（Space）时是否应直接呼出 QuickLook 全图缩放 / 大爆炸预览：
/// - 只要当前检索结果非空，且输入不是显式带参指令、闪念速记或数学算式，普通 Space 一律放大/收起当前选中项（Shift+Space 可输入字面空格）；
/// - 当检索无匹配项，或正在输入 `@密码`、`@锁`、`@建议`、`> 速记`、`[] 待办`、`= 算式` 等指令时，放行原生空格输入。
pub fn should_trigger_quick_look_on_space(
    query: &str,
    latest_clip_text: Option<&str>,
    has_matching_results: bool,
) -> bool {
    if !has_matching_results {
        return false;
    }
    let trimmed = query.trim();
    if trimmed.is_empty() {
        return true;
    }
    if extract_suggestion_payload(query).is_some()
        || parse_quick_capture(query).is_some()
        || crate::security::evaluate_secure_password_query(query).is_some()
        || is_capsule_command_prefix(trimmed)
        || evaluate_instant_math(query, latest_clip_text).is_some()
    {
        return false;
    }
    if trimmed.starts_with('=') || trimmed.starts_with('＝') {
        return false;
    }
    let lower = trimmed.to_lowercase();
    if matches!(
        lower.as_str(),
        "-" | "－"
            | "["
            | "【"
            | "*"
            | "+"
            | "/"
            | "+收藏"
            | "camel"
            | "snake"
            | "kebab"
            | "pascal"
            | "const"
            | "ts"
    ) {
        return false;
    }
    if is_incomplete_arithmetic_expr(trimmed) {
        return false;
    }
    true
}

fn is_capsule_command_prefix(trimmed: &str) -> bool {
    if !trimmed.starts_with('@') {
        return false;
    }
    let lower = trimmed.to_lowercase();
    for p in ["@锁", "@加密", "@lock", "@解锁", "@解密", "@unlock"] {
        if lower == p || lower.starts_with(&format!("{p} ")) || lower.starts_with(&format!("{p}\t"))
        {
            return true;
        }
    }
    false
}

fn is_incomplete_arithmetic_expr(trimmed: &str) -> bool {
    let mut chars = trimmed.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    let Some(last) = trimmed.chars().last() else {
        return false;
    };
    if !(first.is_ascii_digit() || matches!(first, '(' | '（' | '¥' | '￥' | '$')) {
        return false;
    }
    if !matches!(last, '+' | '-' | '*' | '/' | '×' | '÷') {
        return false;
    }
    trimmed.chars().all(|c| {
        c.is_ascii_digit()
            || matches!(
                c,
                '.' | '('
                    | ')'
                    | '（'
                    | '）'
                    | '+'
                    | '-'
                    | '*'
                    | '/'
                    | '×'
                    | '÷'
                    | '%'
                    | '％'
                    | ','
                    | '，'
                    | ' '
                    | '\t'
                    | '¥'
                    | '￥'
                    | '$'
                    | '万'
                    | '亿'
                    | '元'
            )
    })
}
