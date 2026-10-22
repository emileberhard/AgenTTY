use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let root =
        PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR")).join("../..");
    println!(
        "cargo:rerun-if-changed={}",
        root.join("scripts/resolve-build-metadata").display()
    );
    let branch = Command::new("git")
        .args(["symbolic-ref", "--quiet", "HEAD"])
        .current_dir(&root)
        .output()
        .expect("resolve Git branch");
    let branch = String::from_utf8(branch.stdout).expect("UTF-8 Git branch");
    for reference in ["HEAD", "refs/tags", "packed-refs", branch.trim()] {
        if reference.is_empty() {
            continue;
        }
        let output = Command::new("git")
            .args(["rev-parse", "--git-path", reference])
            .current_dir(&root)
            .output()
            .expect("resolve git path");
        assert!(output.status.success(), "Cannot resolve Git identity");
        let path = PathBuf::from(
            String::from_utf8(output.stdout)
                .expect("UTF-8 Git path")
                .trim(),
        );
        println!("cargo:rerun-if-changed={}", root.join(path).display());
    }
    let output = Command::new(root.join("scripts/resolve-build-metadata"))
        .output()
        .expect("resolve build metadata");
    assert!(output.status.success(), "Cannot resolve build metadata");
    for line in String::from_utf8(output.stdout)
        .expect("UTF-8 metadata")
        .lines()
    {
        let (key, value) = line.split_once('=').expect("key=value metadata");
        println!(
            "cargo:rustc-env=AGENTTY_{}={value}",
            if key == "version" {
                "BUILD_VERSION".to_owned()
            } else {
                key.to_uppercase()
            }
        );
    }
}
