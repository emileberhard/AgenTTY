use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

struct BuildMetadata {
    version: String,
    git_sha: String,
    git_tag: String,
}

fn main() {
    let manifest_dir =
        PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR must be set"));
    let repo_root = manifest_dir.join("../..");

    emit_rerun_hints(&repo_root);

    let metadata = resolve_build_metadata(&repo_root);
    println!("cargo:rustc-env=AGENTTY_BUILD_VERSION={}", metadata.version);
    println!("cargo:rustc-env=AGENTTY_GIT_SHA={}", metadata.git_sha);
    println!("cargo:rustc-env=AGENTTY_GIT_TAG={}", metadata.git_tag);
}

fn emit_rerun_hints(repo_root: &Path) {
    println!("cargo:rerun-if-changed=build.rs");
    println!(
        "cargo:rerun-if-changed={}",
        repo_root.join("scripts/resolve-build-metadata").display()
    );

    let git_dir = resolve_git_dir(repo_root);
    let head_path = git_dir.join("HEAD");
    println!("cargo:rerun-if-changed={}", head_path.display());
    println!(
        "cargo:rerun-if-changed={}",
        git_dir.join("packed-refs").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        git_dir.join("refs/tags").display()
    );

    if let Ok(head_contents) = fs::read_to_string(&head_path)
        && let Some(reference) = head_contents.strip_prefix("ref: ").map(str::trim)
    {
        println!(
            "cargo:rerun-if-changed={}",
            git_dir.join(reference).display()
        );
    }
}

fn resolve_git_dir(repo_root: &Path) -> PathBuf {
    let git_path = repo_root.join(".git");
    if git_path.is_dir() {
        return git_path;
    }

    let git_file = fs::read_to_string(&git_path)
        .unwrap_or_else(|error| panic!("failed to read {}: {error}", git_path.display()));
    let relative_git_dir = git_file
        .trim()
        .strip_prefix("gitdir: ")
        .unwrap_or_else(|| panic!("unexpected {} contents", git_path.display()));
    let git_dir = PathBuf::from(relative_git_dir);
    if git_dir.is_absolute() {
        git_dir
    } else {
        repo_root.join(git_dir)
    }
}

fn resolve_build_metadata(repo_root: &Path) -> BuildMetadata {
    let script_path = repo_root.join("scripts/resolve-build-metadata");
    let output = Command::new(&script_path)
        .current_dir(repo_root)
        .output()
        .unwrap_or_else(|error| panic!("failed to run {}: {error}", script_path.display()));
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        panic!(
            "{} exited with status {}: {}",
            script_path.display(),
            output.status,
            stderr.trim()
        );
    }

    let stdout = String::from_utf8(output.stdout).unwrap_or_else(|error| {
        panic!("{} returned invalid UTF-8: {error}", script_path.display())
    });
    let mut version = None;
    let mut git_sha = None;
    let mut git_tag = None;

    for line in stdout.lines() {
        if let Some((key, value)) = line.split_once('=') {
            match key {
                "version" => version = Some(value.to_owned()),
                "git_sha" => git_sha = Some(value.to_owned()),
                "git_tag" => git_tag = Some(value.to_owned()),
                _ => {}
            }
        }
    }

    BuildMetadata {
        version: version
            .unwrap_or_else(|| panic!("{} did not report a build version", script_path.display())),
        git_sha: git_sha
            .unwrap_or_else(|| panic!("{} did not report a git sha", script_path.display())),
        git_tag: git_tag.unwrap_or_default(),
    }
}
