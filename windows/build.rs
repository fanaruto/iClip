use std::env;
use std::fs;
use std::path::PathBuf;

/// Pure-Rust zero-dependency Win32 PE `.res` builder from `assets/iClip.ico`.
/// Embeds `RT_GROUP_ICON` (ordinal ID 1) + `RT_ICON` frames directly into `iClip.exe`
/// via MSVC `link.exe` without requiring external crates or `rc.exe` lookup.
fn main() {
    println!("cargo:rerun-if-changed=assets/iClip.ico");
    println!("cargo:rerun-if-changed=build.rs");

    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        return;
    }

    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let ico_path = manifest_dir.join("assets").join("iClip.ico");
    let ico = fs::read(&ico_path).expect("failed to read windows/assets/iClip.ico");
    if ico.len() < 6 || u16::from_le_bytes([ico[2], ico[3]]) != 1 {
        panic!("invalid ICO header in windows/assets/iClip.ico");
    }

    let count = u16::from_le_bytes([ico[4], ico[5]]) as usize;
    assert!(count > 0 && ico.len() >= 6 + count * 16, "corrupted ICO directory");

    let mut res = Vec::with_capacity(ico.len() + 512);

    // 1. Mandatory 32-bit Windows .res 32-byte empty dummy header
    write_res_record(&mut res, 0, 0, 0x0000, 0x0000, &[]);

    // 2. Individual RT_ICON (type = 3) records, ordinal IDs 1..=count
    let mut grp_dir = Vec::with_capacity(6 + count * 14);
    grp_dir.extend_from_slice(&ico[0..6]); // idReserved(0), idType(1), idCount

    for i in 0..count {
        let entry_off = 6 + i * 16;
        let entry = &ico[entry_off..entry_off + 16];
        let bytes_in_res = u32::from_le_bytes([entry[8], entry[9], entry[10], entry[11]]) as usize;
        let img_off = u32::from_le_bytes([entry[12], entry[13], entry[14], entry[15]]) as usize;
        let img_data = &ico[img_off..img_off + bytes_in_res];

        let icon_id = (i + 1) as u16;
        // RT_ICON = 3, MOVEABLE | PURE = 0x1010, LANG_ENGLISH_US = 0x0409
        write_res_record(&mut res, 3, icon_id, 0x1010, 0x0409, img_data);

        // GRPICONDIRENTRY: first 12 bytes identical to ICONDIRENTRY + 2-byte nID
        grp_dir.extend_from_slice(&entry[0..12]);
        grp_dir.extend_from_slice(&icon_id.to_le_bytes());
    }

    // 3. RT_GROUP_ICON (type = 14), ordinal ID = 1 (primary executable & Explorer icon)
    write_res_record(&mut res, 14, 1, 0x1030, 0x0409, &grp_dir);

    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR"));
    let res_path = out_dir.join("iclip_icon.res");
    fs::write(&res_path, &res).expect("failed to write iclip_icon.res");

    println!("cargo:rustc-link-arg-bins={}", res_path.display());
}

fn write_res_record(
    out: &mut Vec<u8>,
    res_type: u16,
    res_id: u16,
    mem_flags: u16,
    lang_id: u16,
    data: &[u8],
) {
    let data_size = data.len() as u32;
    let header_size: u32 = 32;
    out.extend_from_slice(&data_size.to_le_bytes());
    out.extend_from_slice(&header_size.to_le_bytes());
    // Ordinal Type: 0xFFFF followed by u16 type
    out.extend_from_slice(&0xFFFFu16.to_le_bytes());
    out.extend_from_slice(&res_type.to_le_bytes());
    // Ordinal Name: 0xFFFF followed by u16 id
    out.extend_from_slice(&0xFFFFu16.to_le_bytes());
    out.extend_from_slice(&res_id.to_le_bytes());
    // DataVersion (u32 = 0)
    out.extend_from_slice(&0u32.to_le_bytes());
    // MemoryFlags (u16), LanguageId (u16)
    out.extend_from_slice(&mem_flags.to_le_bytes());
    out.extend_from_slice(&lang_id.to_le_bytes());
    // Version (u32 = 0), Characteristics (u32 = 0)
    out.extend_from_slice(&0u32.to_le_bytes());
    out.extend_from_slice(&0u32.to_le_bytes());

    out.extend_from_slice(data);
    // Pad payload to 4-byte DWORD boundary
    while out.len() % 4 != 0 {
        out.push(0);
    }
}
