use anyhow::{Context, Result, bail};
use rcgen::generate_simple_self_signed;
use std::{
    fs,
    path::{Path, PathBuf},
};

pub struct IdentityMaterial {
    pub certificate_der: Vec<u8>,
    pub private_key_der: Vec<u8>,
    pub persistent: bool,
}

pub fn load_or_create() -> Result<IdentityMaterial> {
    #[cfg(windows)]
    {
        load_or_create_windows()
    }
    #[cfg(target_os = "macos")]
    {
        load_or_create_macos()
    }
    #[cfg(not(any(windows, target_os = "macos")))]
    {
        generate(false)
    }
}

#[cfg(target_os = "macos")]
fn load_or_create_macos() -> Result<IdentityMaterial> {
    use std::os::unix::fs::PermissionsExt;
    let directory = std::env::var_os("SONARA_IDENTITY_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
                .join("Library/Application Support/Sonara/identity")
        });
    fs::create_dir_all(&directory)
        .with_context(|| format!("creating {}", directory.display()))?;
    fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;
    let certificate_path = directory.join("device-certificate.der");
    let key_path = directory.join("device-key.der");
    match (certificate_path.exists(), key_path.exists()) {
        (true, true) => Ok(IdentityMaterial {
            certificate_der: fs::read(&certificate_path)?,
            private_key_der: fs::read(&key_path)?,
            persistent: true,
        }),
        (false, false) => {
            let material = generate(true)?;
            write_new(&key_path, &material.private_key_der)?;
            fs::set_permissions(&key_path, fs::Permissions::from_mode(0o600))?;
            write_new(&certificate_path, &material.certificate_der)?;
            fs::set_permissions(&certificate_path, fs::Permissions::from_mode(0o600))?;
            Ok(material)
        }
        _ => bail!("incomplete device identity in {}", directory.display()),
    }
}

fn generate(persistent: bool) -> Result<IdentityMaterial> {
    let identity = generate_simple_self_signed(vec!["sonara.local".into()])?;
    Ok(IdentityMaterial {
        certificate_der: identity.cert.der().to_vec(),
        private_key_der: identity.signing_key.serialize_der(),
        persistent,
    })
}

#[cfg(windows)]
fn load_or_create_windows() -> Result<IdentityMaterial> {
    let directory = identity_directory()?;
    let certificate_path = directory.join("device-certificate.der");
    let protected_key_path = directory.join("device-key.dpapi");
    match (certificate_path.exists(), protected_key_path.exists()) {
        (true, true) => {
            let certificate_der = fs::read(&certificate_path)
                .with_context(|| format!("reading {}", certificate_path.display()))?;
            let protected = fs::read(&protected_key_path)
                .with_context(|| format!("reading {}", protected_key_path.display()))?;
            let private_key_der =
                dpapi::unprotect(&protected).context("unprotecting device identity with DPAPI")?;
            Ok(IdentityMaterial {
                certificate_der,
                private_key_der,
                persistent: true,
            })
        }
        (false, false) => {
            fs::create_dir_all(&directory)
                .with_context(|| format!("creating {}", directory.display()))?;
            let material = generate(true)?;
            let protected = dpapi::protect(&material.private_key_der)
                .context("protecting device identity with DPAPI")?;
            write_new(&certificate_path, &material.certificate_der)?;
            write_new(&protected_key_path, &protected)?;
            Ok(material)
        }
        _ => bail!(
            "incomplete device identity in {}; remove both identity files to pair again",
            directory.display()
        ),
    }
}

#[cfg(windows)]
fn identity_directory() -> Result<PathBuf> {
    if let Some(override_path) = std::env::var_os("SONARA_IDENTITY_DIR") {
        return Ok(PathBuf::from(override_path));
    }
    let local = std::env::var_os("LOCALAPPDATA").context("LOCALAPPDATA is not set")?;
    Ok(PathBuf::from(local).join("Sonara").join("identity"))
}

#[cfg(any(windows, target_os = "macos"))]
fn write_new(path: &Path, bytes: &[u8]) -> Result<()> {
    use std::io::Write;
    #[cfg(unix)]
    use std::os::unix::fs::OpenOptionsExt;
    let mut options = fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    options.mode(0o600);
    let mut file = options
        .open(path)
        .with_context(|| format!("creating {}", path.display()))?;
    file.write_all(bytes)
        .with_context(|| format!("writing {}", path.display()))?;
    file.sync_all()
        .with_context(|| format!("syncing {}", path.display()))?;
    Ok(())
}

#[cfg(windows)]
mod dpapi {
    use anyhow::{Result, anyhow};
    use std::{ptr, slice};
    use windows_sys::Win32::{
        Foundation::LocalFree,
        Security::Cryptography::{
            CRYPT_INTEGER_BLOB, CRYPTPROTECT_UI_FORBIDDEN, CryptProtectData, CryptUnprotectData,
        },
    };

    pub fn protect(data: &[u8]) -> Result<Vec<u8>> {
        transform(data, true)
    }
    pub fn unprotect(data: &[u8]) -> Result<Vec<u8>> {
        transform(data, false)
    }

    fn transform(data: &[u8], protect: bool) -> Result<Vec<u8>> {
        if data.len() > u32::MAX as usize {
            return Err(anyhow!("identity key is too large"));
        }
        let input = CRYPT_INTEGER_BLOB {
            cbData: data.len() as u32,
            pbData: data.as_ptr().cast_mut(),
        };
        let mut output = CRYPT_INTEGER_BLOB {
            cbData: 0,
            pbData: ptr::null_mut(),
        };
        let success = unsafe {
            if protect {
                CryptProtectData(
                    &input,
                    ptr::null(),
                    ptr::null(),
                    ptr::null_mut(),
                    ptr::null(),
                    CRYPTPROTECT_UI_FORBIDDEN,
                    &mut output,
                )
            } else {
                CryptUnprotectData(
                    &input,
                    ptr::null_mut(),
                    ptr::null(),
                    ptr::null_mut(),
                    ptr::null(),
                    CRYPTPROTECT_UI_FORBIDDEN,
                    &mut output,
                )
            }
        };
        if success == 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        let result =
            unsafe { slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec() };
        unsafe { LocalFree(output.pbData.cast()) };
        Ok(result)
    }
}
