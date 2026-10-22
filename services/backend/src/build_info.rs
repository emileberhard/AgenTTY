#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct BuildInfo {
    pub git_sha: &'static str,
    pub git_tag: Option<&'static str>,
    pub version: &'static str,
}

pub fn current_build_info() -> BuildInfo {
    let git_tag = match env!("AGENTTY_GIT_TAG") {
        "" => None,
        value => Some(value),
    };

    BuildInfo {
        git_sha: env!("AGENTTY_GIT_SHA"),
        git_tag,
        version: env!("AGENTTY_BUILD_VERSION"),
    }
}
