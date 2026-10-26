use std::fmt;
use std::str::FromStr;

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use rand::RngCore;
use rand::rngs::OsRng;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{Map, Value};
use thiserror::Error;

pub const MAIN_BUNDLE_ID: &str = "dev.tuist.agentty.iOS";
const DEVELOPMENT_BUNDLE_SUFFIXES: [&str; 2] = [".dev", ".exp"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PushEnvironment {
    Development,
    Production,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum PushType {
    Alert,
    LiveActivity,
    Location,
    Voip,
}

impl PushType {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Alert => "alert",
            Self::LiveActivity => "liveactivity",
            Self::Location => "location",
            Self::Voip => "voip",
        }
    }
}

impl PushEnvironment {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Development => "development",
            Self::Production => "production",
        }
    }
}

impl fmt::Display for PushEnvironment {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

impl FromStr for PushEnvironment {
    type Err = ParsePushEnvironmentError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "development" => Ok(Self::Development),
            "production" => Ok(Self::Production),
            _ => Err(ParsePushEnvironmentError),
        }
    }
}

impl Serialize for PushEnvironment {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(self.as_str())
    }
}

impl<'de> Deserialize<'de> for PushEnvironment {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        value
            .parse()
            .map_err(|_| serde::de::Error::custom("invalid push environment"))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize)]
pub struct AttemptId(String);

impl AttemptId {
    pub fn generate() -> Self {
        let mut bytes = [0_u8; 8];
        OsRng.fill_bytes(&mut bytes);
        Self(hex::encode(bytes))
    }

    pub fn parse(value: String) -> Result<Self, EmptyStringError> {
        NonEmptyString::new(value.clone())?;
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl Default for AttemptId {
    fn default() -> Self {
        Self::generate()
    }
}

impl fmt::Display for AttemptId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl<'de> Deserialize<'de> for AttemptId {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = NonEmptyString::deserialize(deserializer)?;
        Ok(Self(value.into_inner()))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize)]
#[serde(transparent)]
pub struct NonEmptyString(String);

impl NonEmptyString {
    pub fn new(value: String) -> Result<Self, EmptyStringError> {
        if value.is_empty() {
            return Err(EmptyStringError);
        }
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn into_inner(self) -> String {
        self.0
    }
}

impl fmt::Display for NonEmptyString {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl<'de> Deserialize<'de> for NonEmptyString {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Self::new(value).map_err(|_| serde::de::Error::custom("string must not be empty"))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize)]
#[serde(transparent)]
pub struct DeviceId(String);

impl DeviceId {
    pub fn new(value: String) -> Result<Self, EmptyStringError> {
        let value = normalize_device_id(&value);
        if value.is_empty() {
            return Err(EmptyStringError);
        }
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn into_inner(self) -> String {
        self.0
    }
}

impl fmt::Display for DeviceId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl<'de> Deserialize<'de> for DeviceId {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        Self::new(value).map_err(|_| serde::de::Error::custom("device_id must not be empty"))
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeviceRegistrationRequest {
    pub device_id: DeviceId,
    pub device_secret: NonEmptyString,
    pub apns_token: NonEmptyString,
    pub bundle_id: NonEmptyString,
    pub push_environment: PushEnvironment,
    pub signed_app_transaction: Option<NonEmptyString>,
}

impl DeviceRegistrationRequest {
    pub fn validate_bundle_environment(&self) -> Result<(), BundleEnvironmentError> {
        validate_bundle_environment_pair(self.bundle_id.as_str(), self.push_environment)
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeviceIdentityEnsureRequest {
    pub device_id: DeviceId,
    pub device_secret: NonEmptyString,
    pub bundle_id: NonEmptyString,
    pub push_environment: PushEnvironment,
    pub signed_app_transaction: Option<NonEmptyString>,
}

impl DeviceIdentityEnsureRequest {
    pub fn validate_bundle_environment(&self) -> Result<(), BundleEnvironmentError> {
        validate_bundle_environment_pair(self.bundle_id.as_str(), self.push_environment)
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RelaySessionRequest {
    pub device_id: DeviceId,
    pub device_secret: NonEmptyString,
    #[serde(default)]
    pub scope: NotificationTokenScope,
}

#[derive(Debug, Clone, Copy, Default, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NotificationTokenScope {
    #[default]
    Legacy,
    Notify,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DictationSessionRequest {
    pub device_id: DeviceId,
    pub device_secret: NonEmptyString,
    pub signed_app_transaction: NonEmptyString,
    pub signed_lifetime_transaction: Option<NonEmptyString>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AnalyticsEventType {
    AppSessionCompleted,
    AccessStateSnapshot,
    SshSessionCompleted,
    PurchaseFlowEvent,
    HostSetupFlowEvent,
    PaywallEvent,
    KeyMaterialEvent,
}

impl AnalyticsEventType {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::AppSessionCompleted => "app_session_completed",
            Self::AccessStateSnapshot => "access_state_snapshot",
            Self::SshSessionCompleted => "ssh_session_completed",
            Self::PurchaseFlowEvent => "purchase_flow_event",
            Self::HostSetupFlowEvent => "host_setup_flow_event",
            Self::PaywallEvent => "paywall_event",
            Self::KeyMaterialEvent => "key_material_event",
        }
    }

    pub fn carries_access_state(self) -> bool {
        matches!(self, Self::AppSessionCompleted | Self::AccessStateSnapshot)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AnalyticsAppTransactionEnvironment {
    Production,
    Sandbox,
    Xcode,
}

impl AnalyticsAppTransactionEnvironment {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Production => "production",
            Self::Sandbox => "sandbox",
            Self::Xcode => "xcode",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AnalyticsFlavor {
    Main,
}

impl AnalyticsFlavor {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Main => "main",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AnalyticsPlatform {
    Ios,
}

impl AnalyticsPlatform {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Ios => "ios",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AnalyticsDeviceFamily {
    Phone,
    Pad,
    Mac,
    Tv,
    Carplay,
    Vision,
    Unspecified,
}

impl AnalyticsDeviceFamily {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Phone => "phone",
            Self::Pad => "pad",
            Self::Mac => "mac",
            Self::Tv => "tv",
            Self::Carplay => "carplay",
            Self::Vision => "vision",
            Self::Unspecified => "unspecified",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AnalyticsHostSetupMethod {
    Automatic,
    Manual,
    OneTimePassword,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AnalyticsHostSetupStage {
    ScreenViewed,
    Started,
    AttemptStarted,
    ScannerOpened,
    PairingClaimStarted,
    PairingClaimed,
    PairingCompleted,
    ReviewPresented,
    VerificationStarted,
    VerificationSucceeded,
    VerificationFailed,
    SaveTapped,
    SaveSucceeded,
    SaveSucceededUnreachable,
    SaveSucceededUnverified,
    SaveAnywayTapped,
    TroubleshootOpened,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AnalyticsHostSetupErrorCategory {
    Pairing,
    Reachability,
    ConnectionVerification,
    Save,
    KeyMaterial,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AnalyticsHostCandidateKind {
    TailscaleShort,
    TailscaleFqdn,
    Fqdn,
    SingleLabel,
    LocalDomain,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AnalyticsHostCandidateSource {
    ScutilHostname,
    ScutilLocalhostname,
    HostnameFqdn,
    Hostname,
    OsHostname,
    EnvHostname,
    TailscaleShort,
    TailscaleMagicdns,
    LegacyHostnameCandidates,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AnalyticsHostEnvironmentFlag {
    Container,
    Wsl,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AnalyticsHostPlatform {
    Linux,
    Macos,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AnalyticsReachabilityFailureSubtype {
    Dns,
    Timeout,
    ConnectionRefused,
    NetworkUnreachable,
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AnalyticsPaywallStage {
    Shown,
    PurchaseTapped,
    RestoreTapped,
    RetryLookupTapped,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AnalyticsPurchaseFlowKind {
    Purchase,
    Restore,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AnalyticsPurchaseFlowState {
    Attempted,
    Success,
    Pending,
    Cancelled,
    Failed,
    NotFound,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AnalyticsSshDisconnectCategory {
    ShellClosed,
    ConnectTimeout,
    NetworkError,
    AuthFailed,
    HostKeyMismatch,
    LocalClose,
    TransportClosed,
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AnalyticsSshAuthMode {
    Key,
    PasswordBootstrap,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AnalyticsSshFailureStage {
    TcpConnect,
    SshAuth,
    PreShellRuntime,
    ShellChannel,
    PtyBootstrap,
    TmuxBootstrap,
    Transport,
    PostReadySession,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AnalyticsKeyMaterialOperation {
    Generate,
    Import,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AnalyticsKeyMaterialStage {
    Attempted,
    Succeeded,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AnalyticsKeyMaterialFailureReason {
    RsaUnsupported,
    EncryptedPrivateKeyUnsupported,
    UnsupportedPrivateKeyFormat,
    InvalidPrivateKeyFormat,
    UnsupportedPrivateKeyType,
    KeychainStoreFailed,
    InternalError,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AnalyticsAccessStatePayload {
    pub has_lifetime_access: bool,
    pub trial_expired: bool,
    pub trial_consumed_usage_seconds: f64,
    pub trial_remaining_usage_seconds: f64,
}

impl AnalyticsAccessStatePayload {
    pub fn from_fields(
        has_lifetime_access: bool,
        trial_expired: bool,
        trial_consumed_usage_seconds: f64,
        trial_remaining_usage_seconds: f64,
    ) -> Result<Self, AnalyticsValidationError> {
        if trial_consumed_usage_seconds < 0.0 || trial_remaining_usage_seconds < 0.0 {
            return Err(AnalyticsValidationError::InvalidAccessStatePayload);
        }

        Ok(Self {
            has_lifetime_access,
            trial_expired,
            trial_consumed_usage_seconds,
            trial_remaining_usage_seconds,
        })
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsAccessStateSnapshotPayload {
    #[serde(default)]
    pub app_session_id: Option<NonEmptyString>,
    pub reason: NonEmptyString,
    pub has_finished_initial_access_load: bool,
    pub has_lifetime_access: bool,
    pub trial_expired: bool,
    pub trial_consumed_usage_seconds: f64,
    pub trial_remaining_usage_seconds: f64,
    pub interactive_content_allowed: bool,
    pub gate_blocking: bool,
}

impl AnalyticsAccessStateSnapshotPayload {
    pub fn access_state(&self) -> Result<AnalyticsAccessStatePayload, AnalyticsValidationError> {
        AnalyticsAccessStatePayload::from_fields(
            self.has_lifetime_access,
            self.trial_expired,
            self.trial_consumed_usage_seconds,
            self.trial_remaining_usage_seconds,
        )
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsAppSessionCompletedPayload {
    pub app_session_id: NonEmptyString,
    pub duration_seconds: i64,
    pub has_finished_initial_access_load: bool,
    pub has_lifetime_access: bool,
    pub trial_expired: bool,
    pub trial_consumed_usage_seconds: f64,
    pub trial_remaining_usage_seconds: f64,
    pub interactive_content_allowed: bool,
    pub gate_blocking: bool,
    #[serde(default)]
    pub saved_host_count: i64,
    #[serde(default)]
    pub active_host_present: bool,
    #[serde(default)]
    pub had_paywall_visible: bool,
    #[serde(default)]
    pub ssh_session_count: i64,
    #[serde(default)]
    pub ready_ssh_session_count: i64,
    #[serde(default)]
    pub had_terminal_input: bool,
}

impl AnalyticsAppSessionCompletedPayload {
    pub fn validate(&self) -> Result<(), AnalyticsValidationError> {
        if self.duration_seconds < 0
            || self.saved_host_count < 0
            || self.ssh_session_count < 0
            || self.ready_ssh_session_count < 0
            || self.ready_ssh_session_count > self.ssh_session_count
        {
            return Err(AnalyticsValidationError::InvalidAppSessionPayload);
        }

        let _ = self.access_state()?;
        Ok(())
    }

    pub fn access_state(&self) -> Result<AnalyticsAccessStatePayload, AnalyticsValidationError> {
        AnalyticsAccessStatePayload::from_fields(
            self.has_lifetime_access,
            self.trial_expired,
            self.trial_consumed_usage_seconds,
            self.trial_remaining_usage_seconds,
        )
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsSshSessionCompletedPayload {
    #[serde(default)]
    pub app_session_id: Option<NonEmptyString>,
    pub session_id: NonEmptyString,
    #[serde(default)]
    pub host_id_hash: Option<NonEmptyString>,
    #[serde(default)]
    pub host_key_hash: Option<NonEmptyString>,
    pub duration_seconds: i64,
    pub was_ready: bool,
    #[serde(default)]
    pub disconnect_category: Option<AnalyticsSshDisconnectCategory>,
    #[serde(default)]
    pub disconnect_reason: Option<NonEmptyString>,
    #[serde(default)]
    pub failure_stage: Option<AnalyticsSshFailureStage>,
    #[serde(default)]
    pub had_terminal_input: bool,
    #[serde(default)]
    pub input_event_count: i64,
    #[serde(default)]
    pub auth_mode: Option<AnalyticsSshAuthMode>,
}

impl AnalyticsSshSessionCompletedPayload {
    pub fn validate(&self) -> Result<(), AnalyticsValidationError> {
        if self.duration_seconds < 0 || self.input_event_count < 0 {
            return Err(AnalyticsValidationError::InvalidSshSessionPayload);
        }
        if self.host_id_hash.is_none() && self.host_key_hash.is_none() {
            return Err(AnalyticsValidationError::InvalidSshSessionPayload);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsPurchaseFlowPayload {
    pub kind: AnalyticsPurchaseFlowKind,
    pub state: AnalyticsPurchaseFlowState,
    #[serde(default)]
    pub error_message: Option<NonEmptyString>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsHostSetupFlowPayload {
    #[serde(default)]
    pub app_session_id: Option<NonEmptyString>,
    #[serde(default)]
    pub flow_id: Option<NonEmptyString>,
    pub method: AnalyticsHostSetupMethod,
    pub stage: AnalyticsHostSetupStage,
    pub is_edit: bool,
    pub uses_tailscale_address: bool,
    #[serde(default)]
    pub saved_host_count: Option<i64>,
    #[serde(default)]
    pub host_id_hash: Option<NonEmptyString>,
    #[serde(default)]
    pub error_category: Option<AnalyticsHostSetupErrorCategory>,
    #[serde(default)]
    pub error_message: Option<NonEmptyString>,
    #[serde(default)]
    pub detected_username: Option<NonEmptyString>,
    #[serde(default)]
    pub detected_username_source: Option<PairingDetectedUsernameSource>,
    #[serde(default)]
    pub username_suspicious: Option<bool>,
    #[serde(default)]
    pub host_edited: Option<bool>,
    #[serde(default)]
    pub port_edited: Option<bool>,
    #[serde(default)]
    pub username_edited: Option<bool>,
    #[serde(default)]
    pub selected_candidate_kind: Option<AnalyticsHostCandidateKind>,
    #[serde(default)]
    pub selected_candidate_source: Option<AnalyticsHostCandidateSource>,
    #[serde(default)]
    pub selected_candidate_rank: Option<i64>,
    #[serde(default)]
    pub selected_candidate_value: Option<NonEmptyString>,
    #[serde(default)]
    pub candidate_values: Vec<NonEmptyString>,
    #[serde(default)]
    pub candidate_count: Option<i64>,
    #[serde(default)]
    pub high_confidence_candidate_count: Option<i64>,
    #[serde(default)]
    pub all_low_confidence_candidates: Option<bool>,
    #[serde(default)]
    pub host_platform: Option<AnalyticsHostPlatform>,
    #[serde(default)]
    pub host_environment_flags: Vec<AnalyticsHostEnvironmentFlag>,
    #[serde(default)]
    pub probe_attempt_count: Option<i64>,
    #[serde(default)]
    pub reachability_failure_subtype: Option<AnalyticsReachabilityFailureSubtype>,
    #[serde(default)]
    pub verification_attempt_count: Option<i64>,
    #[serde(default)]
    pub verification_failure_stage: Option<AnalyticsSshFailureStage>,
    #[serde(default)]
    pub verification_disconnect_category: Option<AnalyticsSshDisconnectCategory>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsKeyMaterialPayload {
    #[serde(default)]
    pub app_session_id: Option<NonEmptyString>,
    pub operation: AnalyticsKeyMaterialOperation,
    pub stage: AnalyticsKeyMaterialStage,
    #[serde(default)]
    pub key_type: Option<NonEmptyString>,
    #[serde(default)]
    pub failure_reason: Option<AnalyticsKeyMaterialFailureReason>,
    #[serde(default)]
    pub failure_detail: Option<NonEmptyString>,
}

impl AnalyticsHostSetupFlowPayload {
    pub fn validate(&self) -> Result<(), AnalyticsValidationError> {
        AnalyticsHostSetupFlowPayloadV2::from(self.clone()).validate()
    }
}

impl AnalyticsKeyMaterialPayload {
    pub fn validate(&self) -> Result<(), AnalyticsValidationError> {
        if matches!(self.stage, AnalyticsKeyMaterialStage::Failed) && self.failure_reason.is_none()
        {
            return Err(AnalyticsValidationError::InvalidKeyMaterialPayload);
        }
        if !matches!(self.stage, AnalyticsKeyMaterialStage::Failed) && self.failure_reason.is_some()
        {
            return Err(AnalyticsValidationError::InvalidKeyMaterialPayload);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsPaywallPayload {
    pub stage: AnalyticsPaywallStage,
    pub has_finished_initial_access_load: bool,
    pub has_lifetime_access: bool,
    pub trial_expired: bool,
    pub trial_consumed_usage_seconds: f64,
    pub trial_remaining_usage_seconds: f64,
    pub interactive_content_allowed: bool,
    pub gate_blocking: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsDeviceContext {
    pub system_version: NonEmptyString,
    pub device_model_identifier: NonEmptyString,
    pub device_family: AnalyticsDeviceFamily,
    pub locale_identifier: NonEmptyString,
    #[serde(default)]
    pub preferred_languages: Vec<NonEmptyString>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsContextPayloadV2 {
    pub app_session_id: NonEmptyString,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsAccessStatePayloadV2 {
    pub has_finished_initial_access_load: bool,
    pub has_lifetime_access: bool,
    pub trial_expired: bool,
    pub trial_consumed_usage_seconds: f64,
    pub trial_remaining_usage_seconds: f64,
    pub interactive_content_allowed: bool,
    pub gate_blocking: bool,
}

impl AnalyticsAccessStatePayloadV2 {
    pub fn validate(&self) -> Result<(), AnalyticsValidationError> {
        let _ = self.summary()?;
        Ok(())
    }

    pub fn summary(&self) -> Result<AnalyticsAccessStatePayload, AnalyticsValidationError> {
        AnalyticsAccessStatePayload::from_fields(
            self.has_lifetime_access,
            self.trial_expired,
            self.trial_consumed_usage_seconds,
            self.trial_remaining_usage_seconds,
        )
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsAppSessionInfoPayloadV2 {
    pub id: NonEmptyString,
    pub duration_seconds: i64,
    pub saved_host_count: i64,
    pub active_host_present: bool,
    pub had_paywall_visible: bool,
    pub ssh_session_count: i64,
    pub ready_ssh_session_count: i64,
    pub had_terminal_input: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsSshSessionInfoPayloadV2 {
    pub id: NonEmptyString,
    pub duration_seconds: i64,
    pub was_ready: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsHostReferencePayloadV2 {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id_hash: Option<NonEmptyString>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key_hash: Option<NonEmptyString>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub saved_host_count: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsSshAuthPayloadV2 {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<AnalyticsSshAuthMode>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsSshDisconnectPayloadV2 {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub category: Option<AnalyticsSshDisconnectCategory>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<NonEmptyString>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure_stage: Option<AnalyticsSshFailureStage>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsSshInputPayloadV2 {
    pub had_terminal_input: bool,
    pub event_count: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsPurchaseFlowErrorPayloadV2 {
    pub message: NonEmptyString,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsHostSetupFlowInfoPayloadV2 {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<NonEmptyString>,
    pub method: AnalyticsHostSetupMethod,
    pub stage: AnalyticsHostSetupStage,
    pub is_edit: bool,
    pub uses_tailscale_address: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsHostSetupErrorPayloadV2 {
    pub category: AnalyticsHostSetupErrorCategory,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<NonEmptyString>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsDetectedUsernamePayloadV2 {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<NonEmptyString>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<PairingDetectedUsernameSource>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suspicious: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsHostSetupEditsPayloadV2 {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub port: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub username: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsSelectedCandidatePayloadV2 {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<NonEmptyString>,
    pub kind: AnalyticsHostCandidateKind,
    pub source: AnalyticsHostCandidateSource,
    pub rank: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsCandidateSummaryPayloadV2 {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selected: Option<AnalyticsSelectedCandidatePayloadV2>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub all_values: Vec<NonEmptyString>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub count: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub high_confidence_count: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub all_low_confidence: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsHostEnvironmentPayloadV2 {
    pub platform: AnalyticsHostPlatform,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub flags: Vec<AnalyticsHostEnvironmentFlag>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsReachabilityPayloadV2 {
    pub attempt_count: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure_subtype: Option<AnalyticsReachabilityFailureSubtype>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsVerificationPayloadV2 {
    pub attempt_count: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub failure_stage: Option<AnalyticsSshFailureStage>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub disconnect_category: Option<AnalyticsSshDisconnectCategory>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsKeyPayloadV2 {
    #[serde(rename = "type")]
    pub key_type: NonEmptyString,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsKeyMaterialErrorPayloadV2 {
    pub reason: AnalyticsKeyMaterialFailureReason,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<NonEmptyString>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsAccessStateSnapshotPayloadV2 {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context: Option<AnalyticsContextPayloadV2>,
    pub reason: NonEmptyString,
    pub access_state: AnalyticsAccessStatePayloadV2,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsAppSessionCompletedPayloadV2 {
    pub session: AnalyticsAppSessionInfoPayloadV2,
    pub access_state: AnalyticsAccessStatePayloadV2,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsSshSessionCompletedPayloadV2 {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context: Option<AnalyticsContextPayloadV2>,
    pub session: AnalyticsSshSessionInfoPayloadV2,
    pub host: AnalyticsHostReferencePayloadV2,
    pub auth: AnalyticsSshAuthPayloadV2,
    pub disconnect: AnalyticsSshDisconnectPayloadV2,
    pub input: AnalyticsSshInputPayloadV2,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsPurchaseFlowPayloadV2 {
    pub kind: AnalyticsPurchaseFlowKind,
    pub state: AnalyticsPurchaseFlowState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<AnalyticsPurchaseFlowErrorPayloadV2>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsHostSetupFlowPayloadV2 {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context: Option<AnalyticsContextPayloadV2>,
    pub flow: AnalyticsHostSetupFlowInfoPayloadV2,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<AnalyticsHostReferencePayloadV2>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detected_username: Option<AnalyticsDetectedUsernamePayloadV2>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub edits: Option<AnalyticsHostSetupEditsPayloadV2>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub candidates: Option<AnalyticsCandidateSummaryPayloadV2>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host_environment: Option<AnalyticsHostEnvironmentPayloadV2>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reachability: Option<AnalyticsReachabilityPayloadV2>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub verification: Option<AnalyticsVerificationPayloadV2>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<AnalyticsHostSetupErrorPayloadV2>,
}

#[derive(Debug, Serialize)]
struct AnalyticsRedactedDetectedUsernamePayloadV2 {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<PairingDetectedUsernameSource>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suspicious: Option<bool>,
}

#[derive(Debug, Serialize)]
struct AnalyticsRedactedSelectedCandidatePayloadV2 {
    pub kind: AnalyticsHostCandidateKind,
    pub source: AnalyticsHostCandidateSource,
    pub rank: i64,
}

#[derive(Debug, Serialize)]
struct AnalyticsRedactedCandidateSummaryPayloadV2 {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selected: Option<AnalyticsRedactedSelectedCandidatePayloadV2>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub count: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub high_confidence_count: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub all_low_confidence: Option<bool>,
}

#[derive(Debug, Serialize)]
struct AnalyticsRedactedHostSetupErrorPayloadV2 {
    pub category: AnalyticsHostSetupErrorCategory,
}

#[derive(Debug, Serialize)]
struct AnalyticsRedactedHostSetupFlowPayloadV2 {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context: Option<AnalyticsContextPayloadV2>,
    pub flow: AnalyticsHostSetupFlowInfoPayloadV2,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host: Option<AnalyticsHostReferencePayloadV2>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detected_username: Option<AnalyticsRedactedDetectedUsernamePayloadV2>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub edits: Option<AnalyticsHostSetupEditsPayloadV2>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub candidates: Option<AnalyticsRedactedCandidateSummaryPayloadV2>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub host_environment: Option<AnalyticsHostEnvironmentPayloadV2>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reachability: Option<AnalyticsReachabilityPayloadV2>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub verification: Option<AnalyticsVerificationPayloadV2>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<AnalyticsRedactedHostSetupErrorPayloadV2>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsKeyMaterialPayloadV2 {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context: Option<AnalyticsContextPayloadV2>,
    pub operation: AnalyticsKeyMaterialOperation,
    pub stage: AnalyticsKeyMaterialStage,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<AnalyticsKeyPayloadV2>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<AnalyticsKeyMaterialErrorPayloadV2>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsPaywallPayloadV2 {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context: Option<AnalyticsContextPayloadV2>,
    pub stage: AnalyticsPaywallStage,
    pub access_state: AnalyticsAccessStatePayloadV2,
}

#[derive(Debug, Clone)]
pub struct AnalyticsSensitiveContext {
    pub raw_detected_username: Option<String>,
    pub raw_selected_candidate_value: Option<String>,
    pub raw_candidate_values_json: Option<String>,
    pub raw_disconnect_reason: Option<String>,
    pub raw_error_detail: Option<String>,
}

impl AnalyticsSensitiveContext {
    pub fn is_empty(&self) -> bool {
        self.raw_detected_username.is_none()
            && self.raw_selected_candidate_value.is_none()
            && self.raw_candidate_values_json.is_none()
            && self.raw_disconnect_reason.is_none()
            && self.raw_error_detail.is_none()
    }
}

#[derive(Debug)]
pub struct AnalyticsStoredPayload {
    pub payload_json: String,
    pub sensitive_context: Option<AnalyticsSensitiveContext>,
}

impl From<AnalyticsHostSetupFlowPayload> for AnalyticsHostSetupFlowPayloadV2 {
    fn from(payload: AnalyticsHostSetupFlowPayload) -> Self {
        Self {
            context: payload
                .app_session_id
                .map(|app_session_id| AnalyticsContextPayloadV2 { app_session_id }),
            flow: AnalyticsHostSetupFlowInfoPayloadV2 {
                id: payload.flow_id,
                method: payload.method,
                stage: payload.stage,
                is_edit: payload.is_edit,
                uses_tailscale_address: payload.uses_tailscale_address,
            },
            host: (payload.host_id_hash.is_some() || payload.saved_host_count.is_some()).then_some(
                AnalyticsHostReferencePayloadV2 {
                    id_hash: payload.host_id_hash,
                    key_hash: None,
                    saved_host_count: payload.saved_host_count,
                },
            ),
            detected_username: (payload.detected_username.is_some()
                || payload.detected_username_source.is_some()
                || payload.username_suspicious.is_some())
            .then_some(AnalyticsDetectedUsernamePayloadV2 {
                value: payload.detected_username,
                source: payload.detected_username_source,
                suspicious: payload.username_suspicious,
            }),
            edits: (payload.host_edited.is_some()
                || payload.port_edited.is_some()
                || payload.username_edited.is_some())
            .then_some(AnalyticsHostSetupEditsPayloadV2 {
                host: payload.host_edited,
                port: payload.port_edited,
                username: payload.username_edited,
            }),
            candidates: (payload.selected_candidate_kind.is_some()
                || payload.selected_candidate_source.is_some()
                || payload.selected_candidate_rank.is_some()
                || payload.selected_candidate_value.is_some()
                || !payload.candidate_values.is_empty()
                || payload.candidate_count.is_some()
                || payload.high_confidence_candidate_count.is_some()
                || payload.all_low_confidence_candidates.is_some())
            .then_some(AnalyticsCandidateSummaryPayloadV2 {
                selected: match (
                    payload.selected_candidate_kind,
                    payload.selected_candidate_source,
                    payload.selected_candidate_rank,
                    payload.selected_candidate_value,
                ) {
                    (Some(kind), Some(source), Some(rank), Some(value)) => {
                        Some(AnalyticsSelectedCandidatePayloadV2 {
                            value: Some(value),
                            kind,
                            source,
                            rank,
                        })
                    }
                    _ => None,
                },
                all_values: payload.candidate_values,
                count: payload.candidate_count,
                high_confidence_count: payload.high_confidence_candidate_count,
                all_low_confidence: payload.all_low_confidence_candidates,
            }),
            host_environment: payload.host_platform.map(|platform| {
                AnalyticsHostEnvironmentPayloadV2 {
                    platform,
                    flags: payload.host_environment_flags,
                }
            }),
            reachability: payload.probe_attempt_count.map(|attempt_count| {
                AnalyticsReachabilityPayloadV2 {
                    attempt_count,
                    failure_subtype: payload.reachability_failure_subtype,
                }
            }),
            verification: payload.verification_attempt_count.map(|attempt_count| {
                AnalyticsVerificationPayloadV2 {
                    attempt_count,
                    failure_stage: payload.verification_failure_stage,
                    disconnect_category: payload.verification_disconnect_category,
                }
            }),
            error: payload
                .error_category
                .map(|category| AnalyticsHostSetupErrorPayloadV2 {
                    category,
                    message: payload.error_message,
                }),
        }
    }
}

impl AnalyticsAccessStateSnapshotPayloadV2 {
    pub fn validate(&self) -> Result<(), AnalyticsValidationError> {
        self.access_state.validate()
    }
}

impl AnalyticsAppSessionCompletedPayloadV2 {
    pub fn validate(&self) -> Result<(), AnalyticsValidationError> {
        if self.session.duration_seconds < 0
            || self.session.saved_host_count < 0
            || self.session.ssh_session_count < 0
            || self.session.ready_ssh_session_count < 0
            || self.session.ready_ssh_session_count > self.session.ssh_session_count
        {
            return Err(AnalyticsValidationError::InvalidAppSessionPayload);
        }

        self.access_state.validate()
    }
}

impl AnalyticsSshSessionCompletedPayloadV2 {
    pub fn validate(&self) -> Result<(), AnalyticsValidationError> {
        if self.session.duration_seconds < 0 || self.input.event_count < 0 {
            return Err(AnalyticsValidationError::InvalidSshSessionPayload);
        }
        if self.host.id_hash.is_none() && self.host.key_hash.is_none() {
            return Err(AnalyticsValidationError::InvalidSshSessionPayload);
        }
        Ok(())
    }
}

impl AnalyticsHostSetupFlowPayloadV2 {
    pub fn validate(&self) -> Result<(), AnalyticsValidationError> {
        if self
            .host
            .as_ref()
            .and_then(|host| host.saved_host_count)
            .is_some_and(|count| count < 0)
        {
            return Err(invalid_host_setup_payload(
                "host.saved_host_count",
                "non_negative",
            ));
        }
        if self
            .reachability
            .as_ref()
            .is_some_and(|reachability| reachability.attempt_count <= 0)
        {
            return Err(invalid_host_setup_payload(
                "reachability.attempt_count",
                "positive",
            ));
        }
        if self
            .verification
            .as_ref()
            .is_some_and(|verification| verification.attempt_count <= 0)
        {
            return Err(invalid_host_setup_payload(
                "verification.attempt_count",
                "positive",
            ));
        }

        if let Some(candidates) = self.candidates.as_ref() {
            if candidates
                .selected
                .as_ref()
                .is_some_and(|selected| selected.rank <= 0)
            {
                return Err(invalid_host_setup_payload(
                    "candidates.selected.rank",
                    "positive",
                ));
            }
            if candidates.count.is_some_and(|count| count < 0) {
                return Err(invalid_host_setup_payload(
                    "candidates.count",
                    "non_negative",
                ));
            }
            if candidates
                .high_confidence_count
                .is_some_and(|count| count < 0)
            {
                return Err(invalid_host_setup_payload(
                    "candidates.high_confidence_count",
                    "non_negative",
                ));
            }
            if candidates.count.is_some_and(|count| {
                count != i64::try_from(candidates.all_values.len()).unwrap_or(i64::MAX)
            }) {
                return Err(invalid_host_setup_payload(
                    "candidates.count",
                    "matches_all_values_count",
                ));
            }
            if candidates.selected.is_some() && candidates.count.is_none() {
                return Err(invalid_host_setup_payload(
                    "candidates.selected",
                    "requires_count",
                ));
            }
            if candidates
                .selected
                .as_ref()
                .is_some_and(|selected| selected.value.is_none())
            {
                return Err(invalid_host_setup_payload(
                    "candidates.selected.value",
                    "required",
                ));
            }
            if candidates
                .selected
                .as_ref()
                .is_some_and(|selected| candidates.count.is_some_and(|count| selected.rank > count))
            {
                return Err(invalid_host_setup_payload(
                    "candidates.selected.rank",
                    "within_count",
                ));
            }
            if candidates
                .high_confidence_count
                .zip(candidates.count)
                .is_some_and(|(high_confidence, count)| high_confidence > count)
            {
                return Err(invalid_host_setup_payload(
                    "candidates.high_confidence_count",
                    "at_most_count",
                ));
            }
            if candidates
                .all_low_confidence
                .zip(candidates.high_confidence_count)
                .is_some_and(|(all_low_confidence, high_confidence_count)| {
                    all_low_confidence && high_confidence_count != 0
                })
            {
                return Err(invalid_host_setup_payload(
                    "candidates.all_low_confidence",
                    "requires_zero_high_confidence_count",
                ));
            }
        }

        if matches!(
            self.flow.stage,
            AnalyticsHostSetupStage::VerificationStarted
                | AnalyticsHostSetupStage::VerificationSucceeded
        ) && self.verification.as_ref().is_none_or(|verification| {
            verification.failure_stage.is_some() || verification.disconnect_category.is_some()
        }) {
            return Err(invalid_host_setup_payload(
                "verification",
                "success_requires_attempt_count_without_failure_fields",
            ));
        }
        if matches!(
            self.flow.stage,
            AnalyticsHostSetupStage::VerificationFailed
                | AnalyticsHostSetupStage::SaveSucceededUnverified
        ) && self.verification.as_ref().is_none_or(|verification| {
            verification.failure_stage.is_none() || verification.disconnect_category.is_none()
        }) {
            return Err(invalid_host_setup_payload(
                "verification",
                "failure_requires_stage_and_disconnect_category",
            ));
        }
        if !matches!(
            self.flow.stage,
            AnalyticsHostSetupStage::VerificationStarted
                | AnalyticsHostSetupStage::VerificationSucceeded
                | AnalyticsHostSetupStage::VerificationFailed
                | AnalyticsHostSetupStage::SaveSucceededUnverified
        ) && self.verification.is_some()
        {
            return Err(invalid_host_setup_payload(
                "verification",
                "allowed_only_for_verification_stages",
            ));
        }
        Ok(())
    }

    pub fn redacted_payload_shape_json(&self) -> Option<String> {
        serde_json::to_string(&self.redacted_payload()).ok()
    }

    fn redacted_payload(&self) -> AnalyticsRedactedHostSetupFlowPayloadV2 {
        let detected_username = self.detected_username.as_ref().map(|detected_username| {
            AnalyticsRedactedDetectedUsernamePayloadV2 {
                source: detected_username.source,
                suspicious: detected_username.suspicious,
            }
        });

        let candidates = self.candidates.as_ref().map(|candidates| {
            let selected = candidates.selected.as_ref().map(|selected| {
                AnalyticsRedactedSelectedCandidatePayloadV2 {
                    kind: selected.kind,
                    source: selected.source,
                    rank: selected.rank,
                }
            });
            AnalyticsRedactedCandidateSummaryPayloadV2 {
                selected,
                count: candidates.count,
                high_confidence_count: candidates.high_confidence_count,
                all_low_confidence: candidates.all_low_confidence,
            }
        });

        let error = self
            .error
            .as_ref()
            .map(|error| AnalyticsRedactedHostSetupErrorPayloadV2 {
                category: error.category,
            });

        AnalyticsRedactedHostSetupFlowPayloadV2 {
            context: self.context.clone(),
            flow: self.flow.clone(),
            host: self.host.clone(),
            detected_username,
            edits: self.edits.clone(),
            candidates,
            host_environment: self.host_environment.clone(),
            reachability: self.reachability.clone(),
            verification: self.verification.clone(),
            error,
        }
    }
}

fn invalid_host_setup_payload(field: &'static str, rule: &'static str) -> AnalyticsValidationError {
    AnalyticsValidationError::InvalidHostSetupPayload { field, rule }
}

impl AnalyticsKeyMaterialPayloadV2 {
    pub fn validate(&self) -> Result<(), AnalyticsValidationError> {
        if matches!(self.stage, AnalyticsKeyMaterialStage::Failed) && self.error.is_none() {
            return Err(AnalyticsValidationError::InvalidKeyMaterialPayload);
        }
        if !matches!(self.stage, AnalyticsKeyMaterialStage::Failed) && self.error.is_some() {
            return Err(AnalyticsValidationError::InvalidKeyMaterialPayload);
        }
        Ok(())
    }
}

impl AnalyticsPaywallPayloadV2 {
    pub fn validate(&self) -> Result<(), AnalyticsValidationError> {
        self.access_state.validate()
    }
}

#[derive(Debug, Clone)]
pub enum AnalyticsParsedEventPayload {
    AppSessionCompleted(AnalyticsAppSessionCompletedPayloadV2),
    AccessStateSnapshot(AnalyticsAccessStateSnapshotPayloadV2),
    SshSessionCompleted(AnalyticsSshSessionCompletedPayloadV2),
    PurchaseFlow(AnalyticsPurchaseFlowPayloadV2),
    HostSetupFlow(AnalyticsHostSetupFlowPayloadV2),
    Paywall(AnalyticsPaywallPayloadV2),
    KeyMaterial(AnalyticsKeyMaterialPayloadV2),
}

impl AnalyticsParsedEventPayload {
    pub fn access_state(
        &self,
    ) -> Result<Option<AnalyticsAccessStatePayload>, AnalyticsValidationError> {
        match self {
            Self::AppSessionCompleted(payload) => payload.access_state.summary().map(Some),
            Self::AccessStateSnapshot(payload) => payload.access_state.summary().map(Some),
            Self::Paywall(payload) => payload.access_state.summary().map(Some),
            Self::SshSessionCompleted(_)
            | Self::PurchaseFlow(_)
            | Self::HostSetupFlow(_)
            | Self::KeyMaterial(_) => Ok(None),
        }
    }

    pub fn saved_host_count(&self) -> Option<i64> {
        match self {
            Self::AppSessionCompleted(payload) => Some(payload.session.saved_host_count),
            Self::HostSetupFlow(payload) => {
                payload.host.as_ref().and_then(|host| host.saved_host_count)
            }
            Self::AccessStateSnapshot(_)
            | Self::SshSessionCompleted(_)
            | Self::PurchaseFlow(_)
            | Self::Paywall(_)
            | Self::KeyMaterial(_) => None,
        }
    }

    pub fn into_storage_payload(self) -> Result<AnalyticsStoredPayload, AnalyticsValidationError> {
        match self {
            Self::AppSessionCompleted(payload) => Ok(AnalyticsStoredPayload {
                payload_json: serde_json::to_string(&payload)
                    .map_err(|_| AnalyticsValidationError::InvalidAppSessionPayload)?,
                sensitive_context: None,
            }),
            Self::AccessStateSnapshot(payload) => Ok(AnalyticsStoredPayload {
                payload_json: serde_json::to_string(&payload)
                    .map_err(|_| AnalyticsValidationError::InvalidAccessStateSnapshotPayload)?,
                sensitive_context: None,
            }),
            Self::SshSessionCompleted(mut payload) => {
                let sensitive_context =
                    payload
                        .disconnect
                        .reason
                        .take()
                        .map(|reason| AnalyticsSensitiveContext {
                            raw_detected_username: None,
                            raw_selected_candidate_value: None,
                            raw_candidate_values_json: None,
                            raw_disconnect_reason: Some(reason.into_inner()),
                            raw_error_detail: None,
                        });
                Ok(AnalyticsStoredPayload {
                    payload_json: serde_json::to_string(&payload)
                        .map_err(|_| AnalyticsValidationError::InvalidSshSessionPayload)?,
                    sensitive_context,
                })
            }
            Self::PurchaseFlow(mut payload) => {
                let sensitive_context =
                    payload.error.take().map(|error| AnalyticsSensitiveContext {
                        raw_detected_username: None,
                        raw_selected_candidate_value: None,
                        raw_candidate_values_json: None,
                        raw_disconnect_reason: None,
                        raw_error_detail: Some(error.message.into_inner()),
                    });
                Ok(AnalyticsStoredPayload {
                    payload_json: serde_json::to_string(&payload)
                        .map_err(|_| AnalyticsValidationError::InvalidPurchaseFlowPayload)?,
                    sensitive_context,
                })
            }
            Self::HostSetupFlow(payload) => {
                let mut sensitive_context = AnalyticsSensitiveContext {
                    raw_detected_username: None,
                    raw_selected_candidate_value: None,
                    raw_candidate_values_json: None,
                    raw_disconnect_reason: None,
                    raw_error_detail: None,
                };

                let detected_username = payload.detected_username.map(|detected_username| {
                    sensitive_context.raw_detected_username =
                        detected_username.value.map(NonEmptyString::into_inner);
                    AnalyticsRedactedDetectedUsernamePayloadV2 {
                        source: detected_username.source,
                        suspicious: detected_username.suspicious,
                    }
                });

                let candidates = payload.candidates.map(|candidates| {
                    if !candidates.all_values.is_empty() {
                        sensitive_context.raw_candidate_values_json =
                            serde_json::to_string(&candidates.all_values).ok();
                    }
                    let selected = candidates.selected.map(|selected| {
                        sensitive_context.raw_selected_candidate_value =
                            selected.value.map(NonEmptyString::into_inner);
                        AnalyticsRedactedSelectedCandidatePayloadV2 {
                            kind: selected.kind,
                            source: selected.source,
                            rank: selected.rank,
                        }
                    });
                    AnalyticsRedactedCandidateSummaryPayloadV2 {
                        selected,
                        count: candidates.count,
                        high_confidence_count: candidates.high_confidence_count,
                        all_low_confidence: candidates.all_low_confidence,
                    }
                });

                let error = payload.error.map(|error| {
                    sensitive_context.raw_error_detail =
                        error.message.map(NonEmptyString::into_inner);
                    AnalyticsRedactedHostSetupErrorPayloadV2 {
                        category: error.category,
                    }
                });

                let redacted_payload = AnalyticsRedactedHostSetupFlowPayloadV2 {
                    context: payload.context,
                    flow: payload.flow,
                    host: payload.host,
                    detected_username,
                    edits: payload.edits,
                    candidates,
                    host_environment: payload.host_environment,
                    reachability: payload.reachability,
                    verification: payload.verification,
                    error,
                };

                Ok(AnalyticsStoredPayload {
                    payload_json: serde_json::to_string(&redacted_payload)
                        .map_err(|_| invalid_host_setup_payload("payload", "serializable"))?,
                    sensitive_context: (!sensitive_context.is_empty()).then_some(sensitive_context),
                })
            }
            Self::Paywall(payload) => Ok(AnalyticsStoredPayload {
                payload_json: serde_json::to_string(&payload)
                    .map_err(|_| AnalyticsValidationError::InvalidPaywallPayload)?,
                sensitive_context: None,
            }),
            Self::KeyMaterial(mut payload) => {
                let sensitive_context = payload.error.as_mut().and_then(|error| {
                    error.detail.take().map(|detail| AnalyticsSensitiveContext {
                        raw_detected_username: None,
                        raw_selected_candidate_value: None,
                        raw_candidate_values_json: None,
                        raw_disconnect_reason: None,
                        raw_error_detail: Some(detail.into_inner()),
                    })
                });
                Ok(AnalyticsStoredPayload {
                    payload_json: serde_json::to_string(&payload)
                        .map_err(|_| AnalyticsValidationError::InvalidKeyMaterialPayload)?,
                    sensitive_context,
                })
            }
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsEventRequest {
    pub event_id: NonEmptyString,
    pub event_type: AnalyticsEventType,
    pub occurred_at_epoch_seconds: i64,
    #[serde(default)]
    pub payload_version: Option<u8>,
    pub payload: Value,
}

#[derive(Debug, Clone)]
pub struct ValidatedAnalyticsEvent {
    pub event_id: NonEmptyString,
    pub event_type: AnalyticsEventType,
    pub occurred_at_epoch_seconds: i64,
    pub payload_version: u8,
    pub parsed_payload: AnalyticsParsedEventPayload,
}

#[derive(Debug, Clone)]
pub struct ValidatedAnalyticsIngestRequest {
    pub device_id: DeviceId,
    pub device_secret: NonEmptyString,
    pub app_transaction_id: NonEmptyString,
    pub original_purchase_date_epoch_seconds: i64,
    pub bundle_id: NonEmptyString,
    pub app_transaction_environment: AnalyticsAppTransactionEnvironment,
    pub app_version: NonEmptyString,
    pub build_number: NonEmptyString,
    pub flavor: AnalyticsFlavor,
    pub platform: AnalyticsPlatform,
    pub device_context: Option<AnalyticsDeviceContext>,
    pub events: Vec<ValidatedAnalyticsEvent>,
}

#[derive(Debug, Clone)]
pub struct AnalyticsValidationDiagnostic {
    pub failed_event_id: Option<String>,
    pub failed_event_type: Option<String>,
    pub validation_field: Option<String>,
    pub validation_rule: Option<String>,
    pub payload_version: Option<i64>,
    pub redacted_payload_shape_json: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AnalyticsIngestRequest {
    pub device_id: DeviceId,
    pub device_secret: NonEmptyString,
    pub app_transaction_id: NonEmptyString,
    pub original_purchase_date_epoch_seconds: i64,
    pub bundle_id: NonEmptyString,
    pub app_transaction_environment: AnalyticsAppTransactionEnvironment,
    pub app_version: NonEmptyString,
    pub build_number: NonEmptyString,
    pub flavor: AnalyticsFlavor,
    pub platform: AnalyticsPlatform,
    #[serde(default)]
    pub device_context: Option<AnalyticsDeviceContext>,
    pub events: Vec<AnalyticsEventRequest>,
}

impl AnalyticsEventRequest {
    fn redacted_payload_shape_json(&self, payload_version: u8) -> Option<String> {
        if self.event_type != AnalyticsEventType::HostSetupFlowEvent {
            return None;
        }

        match payload_version {
            1 => serde_json::from_value::<AnalyticsHostSetupFlowPayload>(self.payload.clone())
                .ok()
                .map(AnalyticsHostSetupFlowPayloadV2::from)
                .and_then(|payload| payload.redacted_payload_shape_json()),
            2 => serde_json::from_value::<AnalyticsHostSetupFlowPayloadV2>(self.payload.clone())
                .ok()
                .and_then(|payload| payload.redacted_payload_shape_json()),
            _ => None,
        }
    }

    fn into_validated(self) -> Result<ValidatedAnalyticsEvent, AnalyticsValidationError> {
        if self.occurred_at_epoch_seconds <= 0 {
            return Err(AnalyticsValidationError::NonPositiveEventTimestamp);
        }
        let payload_version = self.payload_version.unwrap_or(1);
        let parsed_payload = self.parsed_payload(payload_version)?;
        Ok(ValidatedAnalyticsEvent {
            event_id: self.event_id,
            event_type: self.event_type,
            occurred_at_epoch_seconds: self.occurred_at_epoch_seconds,
            payload_version,
            parsed_payload,
        })
    }

    pub fn parsed_payload(
        &self,
        payload_version: u8,
    ) -> Result<AnalyticsParsedEventPayload, AnalyticsValidationError> {
        if !self.payload.is_object() {
            return Err(AnalyticsValidationError::PayloadMustBeObject);
        }

        match payload_version {
            1 => self.parsed_payload_v1(),
            2 => self.parsed_payload_v2(),
            other => Err(AnalyticsValidationError::UnsupportedPayloadVersion(other)),
        }
    }

    fn parsed_payload_v1(&self) -> Result<AnalyticsParsedEventPayload, AnalyticsValidationError> {
        match self.event_type {
            AnalyticsEventType::AppSessionCompleted => {
                Ok(AnalyticsParsedEventPayload::AppSessionCompleted(
                    parse_app_session_completed_payload_v1_or_v2(&self.payload)?,
                ))
            }
            AnalyticsEventType::AccessStateSnapshot => {
                let payload: AnalyticsAccessStateSnapshotPayload =
                    serde_json::from_value(self.payload.clone())
                        .map_err(|_| AnalyticsValidationError::InvalidAccessStateSnapshotPayload)?;
                let _ = payload.access_state()?;
                Ok(AnalyticsParsedEventPayload::AccessStateSnapshot(
                    AnalyticsAccessStateSnapshotPayloadV2 {
                        context: payload
                            .app_session_id
                            .map(|app_session_id| AnalyticsContextPayloadV2 { app_session_id }),
                        reason: payload.reason,
                        access_state: AnalyticsAccessStatePayloadV2 {
                            has_finished_initial_access_load: payload
                                .has_finished_initial_access_load,
                            has_lifetime_access: payload.has_lifetime_access,
                            trial_expired: payload.trial_expired,
                            trial_consumed_usage_seconds: payload.trial_consumed_usage_seconds,
                            trial_remaining_usage_seconds: payload.trial_remaining_usage_seconds,
                            interactive_content_allowed: payload.interactive_content_allowed,
                            gate_blocking: payload.gate_blocking,
                        },
                    },
                ))
            }
            AnalyticsEventType::SshSessionCompleted => {
                let payload: AnalyticsSshSessionCompletedPayload =
                    serde_json::from_value(self.payload.clone())
                        .map_err(|_| AnalyticsValidationError::InvalidSshSessionPayload)?;
                payload.validate()?;
                Ok(AnalyticsParsedEventPayload::SshSessionCompleted(
                    AnalyticsSshSessionCompletedPayloadV2 {
                        context: payload
                            .app_session_id
                            .map(|app_session_id| AnalyticsContextPayloadV2 { app_session_id }),
                        session: AnalyticsSshSessionInfoPayloadV2 {
                            id: payload.session_id,
                            duration_seconds: payload.duration_seconds,
                            was_ready: payload.was_ready,
                        },
                        host: AnalyticsHostReferencePayloadV2 {
                            id_hash: payload.host_id_hash,
                            key_hash: payload.host_key_hash,
                            saved_host_count: None,
                        },
                        auth: AnalyticsSshAuthPayloadV2 {
                            mode: payload.auth_mode,
                        },
                        disconnect: AnalyticsSshDisconnectPayloadV2 {
                            category: payload.disconnect_category,
                            reason: payload.disconnect_reason,
                            failure_stage: payload.failure_stage,
                        },
                        input: AnalyticsSshInputPayloadV2 {
                            had_terminal_input: payload.had_terminal_input,
                            event_count: payload.input_event_count,
                        },
                    },
                ))
            }
            AnalyticsEventType::PurchaseFlowEvent => {
                let payload: AnalyticsPurchaseFlowPayload =
                    serde_json::from_value(self.payload.clone())
                        .map_err(|_| AnalyticsValidationError::InvalidPurchaseFlowPayload)?;
                Ok(AnalyticsParsedEventPayload::PurchaseFlow(
                    AnalyticsPurchaseFlowPayloadV2 {
                        kind: payload.kind,
                        state: payload.state,
                        error: payload
                            .error_message
                            .map(|message| AnalyticsPurchaseFlowErrorPayloadV2 { message }),
                    },
                ))
            }
            AnalyticsEventType::HostSetupFlowEvent => {
                let payload: AnalyticsHostSetupFlowPayload =
                    serde_json::from_value(self.payload.clone()).map_err(|_| {
                        invalid_host_setup_payload("payload", "matches_host_setup_schema")
                    })?;
                let payload = AnalyticsHostSetupFlowPayloadV2::from(payload);
                payload.validate()?;
                Ok(AnalyticsParsedEventPayload::HostSetupFlow(payload))
            }
            AnalyticsEventType::PaywallEvent => {
                let payload: AnalyticsPaywallPayload = serde_json::from_value(self.payload.clone())
                    .map_err(|_| AnalyticsValidationError::InvalidPaywallPayload)?;
                let _ = AnalyticsAccessStatePayload::from_fields(
                    payload.has_lifetime_access,
                    payload.trial_expired,
                    payload.trial_consumed_usage_seconds,
                    payload.trial_remaining_usage_seconds,
                )?;
                Ok(AnalyticsParsedEventPayload::Paywall(
                    AnalyticsPaywallPayloadV2 {
                        context: None,
                        stage: payload.stage,
                        access_state: AnalyticsAccessStatePayloadV2 {
                            has_finished_initial_access_load: payload
                                .has_finished_initial_access_load,
                            has_lifetime_access: payload.has_lifetime_access,
                            trial_expired: payload.trial_expired,
                            trial_consumed_usage_seconds: payload.trial_consumed_usage_seconds,
                            trial_remaining_usage_seconds: payload.trial_remaining_usage_seconds,
                            interactive_content_allowed: payload.interactive_content_allowed,
                            gate_blocking: payload.gate_blocking,
                        },
                    },
                ))
            }
            AnalyticsEventType::KeyMaterialEvent => {
                let payload: AnalyticsKeyMaterialPayload =
                    serde_json::from_value(self.payload.clone())
                        .map_err(|_| AnalyticsValidationError::InvalidKeyMaterialPayload)?;
                payload.validate()?;
                Ok(AnalyticsParsedEventPayload::KeyMaterial(
                    AnalyticsKeyMaterialPayloadV2 {
                        context: payload
                            .app_session_id
                            .map(|app_session_id| AnalyticsContextPayloadV2 { app_session_id }),
                        operation: payload.operation,
                        stage: payload.stage,
                        key: payload
                            .key_type
                            .map(|key_type| AnalyticsKeyPayloadV2 { key_type }),
                        error: payload.failure_reason.map(|reason| {
                            AnalyticsKeyMaterialErrorPayloadV2 {
                                reason,
                                detail: payload.failure_detail,
                            }
                        }),
                    },
                ))
            }
        }
    }

    fn parsed_payload_v2(&self) -> Result<AnalyticsParsedEventPayload, AnalyticsValidationError> {
        match self.event_type {
            AnalyticsEventType::AppSessionCompleted => {
                Ok(AnalyticsParsedEventPayload::AppSessionCompleted(
                    parse_app_session_completed_payload_v2_or_v1(&self.payload)?,
                ))
            }
            AnalyticsEventType::AccessStateSnapshot => {
                let payload: AnalyticsAccessStateSnapshotPayloadV2 =
                    serde_json::from_value(self.payload.clone())
                        .map_err(|_| AnalyticsValidationError::InvalidAccessStateSnapshotPayload)?;
                payload.validate()?;
                Ok(AnalyticsParsedEventPayload::AccessStateSnapshot(payload))
            }
            AnalyticsEventType::SshSessionCompleted => {
                let payload: AnalyticsSshSessionCompletedPayloadV2 =
                    serde_json::from_value(self.payload.clone())
                        .map_err(|_| AnalyticsValidationError::InvalidSshSessionPayload)?;
                payload.validate()?;
                Ok(AnalyticsParsedEventPayload::SshSessionCompleted(payload))
            }
            AnalyticsEventType::PurchaseFlowEvent => {
                let payload: AnalyticsPurchaseFlowPayloadV2 =
                    serde_json::from_value(self.payload.clone())
                        .map_err(|_| AnalyticsValidationError::InvalidPurchaseFlowPayload)?;
                Ok(AnalyticsParsedEventPayload::PurchaseFlow(payload))
            }
            AnalyticsEventType::HostSetupFlowEvent => {
                let payload: AnalyticsHostSetupFlowPayloadV2 =
                    serde_json::from_value(self.payload.clone()).map_err(|_| {
                        invalid_host_setup_payload("payload", "matches_host_setup_schema")
                    })?;
                payload.validate()?;
                Ok(AnalyticsParsedEventPayload::HostSetupFlow(payload))
            }
            AnalyticsEventType::PaywallEvent => {
                let payload: AnalyticsPaywallPayloadV2 =
                    serde_json::from_value(self.payload.clone())
                        .map_err(|_| AnalyticsValidationError::InvalidPaywallPayload)?;
                payload.validate()?;
                Ok(AnalyticsParsedEventPayload::Paywall(payload))
            }
            AnalyticsEventType::KeyMaterialEvent => {
                let payload: AnalyticsKeyMaterialPayloadV2 =
                    serde_json::from_value(self.payload.clone())
                        .map_err(|_| AnalyticsValidationError::InvalidKeyMaterialPayload)?;
                payload.validate()?;
                Ok(AnalyticsParsedEventPayload::KeyMaterial(payload))
            }
        }
    }
}

fn parse_legacy_app_session_completed_payload(
    payload: &Value,
) -> Result<AnalyticsAppSessionCompletedPayloadV2, AnalyticsValidationError> {
    let payload: AnalyticsAppSessionCompletedPayload = serde_json::from_value(payload.clone())
        .map_err(|_| AnalyticsValidationError::InvalidAppSessionPayload)?;
    payload.validate()?;
    Ok(AnalyticsAppSessionCompletedPayloadV2 {
        session: AnalyticsAppSessionInfoPayloadV2 {
            id: payload.app_session_id,
            duration_seconds: payload.duration_seconds,
            saved_host_count: payload.saved_host_count,
            active_host_present: payload.active_host_present,
            had_paywall_visible: payload.had_paywall_visible,
            ssh_session_count: payload.ssh_session_count,
            ready_ssh_session_count: payload.ready_ssh_session_count,
            had_terminal_input: payload.had_terminal_input,
        },
        access_state: AnalyticsAccessStatePayloadV2 {
            has_finished_initial_access_load: payload.has_finished_initial_access_load,
            has_lifetime_access: payload.has_lifetime_access,
            trial_expired: payload.trial_expired,
            trial_consumed_usage_seconds: payload.trial_consumed_usage_seconds,
            trial_remaining_usage_seconds: payload.trial_remaining_usage_seconds,
            interactive_content_allowed: payload.interactive_content_allowed,
            gate_blocking: payload.gate_blocking,
        },
    })
}

fn parse_nested_app_session_completed_payload(
    payload: &Value,
) -> Result<AnalyticsAppSessionCompletedPayloadV2, AnalyticsValidationError> {
    let payload: AnalyticsAppSessionCompletedPayloadV2 = serde_json::from_value(payload.clone())
        .map_err(|_| AnalyticsValidationError::InvalidAppSessionPayload)?;
    payload.validate()?;
    Ok(payload)
}

fn parse_app_session_completed_payload_v1_or_v2(
    payload: &Value,
) -> Result<AnalyticsAppSessionCompletedPayloadV2, AnalyticsValidationError> {
    parse_legacy_app_session_completed_payload(payload)
        .or_else(|_| parse_nested_app_session_completed_payload(payload))
}

fn parse_app_session_completed_payload_v2_or_v1(
    payload: &Value,
) -> Result<AnalyticsAppSessionCompletedPayloadV2, AnalyticsValidationError> {
    parse_nested_app_session_completed_payload(payload)
        .or_else(|_| parse_legacy_app_session_completed_payload(payload))
}

impl AnalyticsIngestRequest {
    pub fn validation_diagnostic(
        &self,
        error: &AnalyticsValidationError,
    ) -> AnalyticsValidationDiagnostic {
        let event_diagnostic = error
            .is_event_scoped()
            .then(|| {
                self.events.iter().find_map(|event| {
                    let payload_version = event.payload_version.unwrap_or(1);
                    event
                        .clone()
                        .into_validated()
                        .err()
                        .map(|event_error| (event, payload_version, event_error))
                })
            })
            .flatten();

        if let Some((event, payload_version, event_error)) = event_diagnostic {
            AnalyticsValidationDiagnostic {
                failed_event_id: Some(event.event_id.as_str().to_owned()),
                failed_event_type: Some(event.event_type.as_str().to_owned()),
                validation_field: event_error.field().map(str::to_owned),
                validation_rule: event_error.rule().map(str::to_owned),
                payload_version: Some(i64::from(payload_version)),
                redacted_payload_shape_json: event.redacted_payload_shape_json(payload_version),
            }
        } else {
            AnalyticsValidationDiagnostic {
                failed_event_id: None,
                failed_event_type: None,
                validation_field: error.field().map(str::to_owned),
                validation_rule: error.rule().map(str::to_owned),
                payload_version: None,
                redacted_payload_shape_json: None,
            }
        }
    }

    pub fn validate(self) -> Result<ValidatedAnalyticsIngestRequest, AnalyticsValidationError> {
        if self.events.is_empty() {
            return Err(AnalyticsValidationError::EmptyEventBatch);
        }
        if self.original_purchase_date_epoch_seconds <= 0 {
            return Err(AnalyticsValidationError::NonPositiveOriginalPurchaseDate);
        }
        if self.bundle_id.as_str() != MAIN_BUNDLE_ID {
            return Err(AnalyticsValidationError::UnsupportedBundle);
        }
        if self.flavor != AnalyticsFlavor::Main {
            return Err(AnalyticsValidationError::UnsupportedFlavor);
        }
        let events = self
            .events
            .into_iter()
            .map(AnalyticsEventRequest::into_validated)
            .collect::<Result<Vec<_>, _>>()?;
        Ok(ValidatedAnalyticsIngestRequest {
            device_id: self.device_id,
            device_secret: self.device_secret,
            app_transaction_id: self.app_transaction_id,
            original_purchase_date_epoch_seconds: self.original_purchase_date_epoch_seconds,
            bundle_id: self.bundle_id,
            app_transaction_environment: self.app_transaction_environment,
            app_version: self.app_version,
            build_number: self.build_number,
            flavor: self.flavor,
            platform: self.platform,
            device_context: self.device_context,
            events,
        })
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct RelaySessionResponse {
    pub relay_token: String,
    pub expires_at_epoch_seconds: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dictation_tier: Option<&'static str>,
}

impl RelaySessionResponse {
    pub fn new(expires_at_epoch_seconds: i64) -> Self {
        let mut bytes = [0_u8; 32];
        OsRng.fill_bytes(&mut bytes);
        Self {
            relay_token: URL_SAFE_NO_PAD.encode(bytes),
            expires_at_epoch_seconds,
            dictation_tier: None,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DictationTranscriptionRequest {
    pub audio_base64: NonEmptyString,
    pub mime_type: NonEmptyString,
    pub file_name: NonEmptyString,
    pub instructions: Option<NonEmptyString>,
    #[serde(default)]
    pub language_hints: Vec<NonEmptyString>,
}

#[derive(Debug, Clone, Serialize)]
pub struct DictationTranscriptionResponse {
    pub text: String,
    pub seconds_charged: i64,
    pub remaining_seconds_this_week: i64,
    pub quota_resets_at_epoch_seconds: i64,
}

const PAIRING_CODE_ALPHABET: &[u8; 32] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PairingSessionStatusRequest {
    pub device_id: DeviceId,
    pub device_secret: NonEmptyString,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PairingSessionHostStatusRequest {
    pub host_token: NonEmptyString,
}

#[derive(Debug, Clone, Serialize)]
pub struct ConnectorBootstrapPayload {
    pub token: String,
    pub expires_at_epoch_seconds: i64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PairingSessionClaimRequest {
    pub code: NonEmptyString,
    pub device_id: DeviceId,
    pub device_secret: NonEmptyString,
    pub public_key: NonEmptyString,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PairingSessionCompleteRequest {
    pub host_token: NonEmptyString,
    pub detected_username: Option<NonEmptyString>,
    #[serde(default)]
    pub detected_username_source: Option<PairingDetectedUsernameSource>,
    #[serde(default)]
    pub detected_username_suspicious: bool,
    #[serde(default)]
    pub host_candidates: Vec<PairingHostCandidateInput>,
    #[serde(default)]
    pub host_environment_flags: Vec<PairingHostEnvironmentFlag>,
    #[serde(default)]
    pub hostname_candidates: Vec<NonEmptyString>,
    #[serde(default)]
    pub uses_tailscale: bool,
    #[serde(default)]
    pub ssh_host_public_keys: Vec<NonEmptyString>,
    pub relay_host_id: Option<NonEmptyString>,
    #[serde(default)]
    pub relay_capable: bool,
    pub port: Option<u16>,
    pub platform: Option<PairingPlatform>,
    pub error_message: Option<NonEmptyString>,
}

impl PairingSessionCompleteRequest {
    pub fn into_completion(self) -> PairingCompletionPayload {
        let hostname_candidates = self
            .hostname_candidates
            .into_iter()
            .map(NonEmptyString::into_inner)
            .collect::<Vec<_>>();
        let host_candidates = if self.host_candidates.is_empty() {
            legacy_pairing_host_candidates(&hostname_candidates)
        } else {
            self.host_candidates
                .into_iter()
                .map(PairingHostCandidateInput::into_candidate)
                .collect()
        };
        PairingCompletionPayload {
            detected_username: self.detected_username.map(NonEmptyString::into_inner),
            detected_username_source: self.detected_username_source,
            detected_username_suspicious: self.detected_username_suspicious,
            host_candidates,
            host_environment_flags: self.host_environment_flags,
            hostname_candidates,
            uses_tailscale: self.uses_tailscale,
            ssh_host_public_keys: self
                .ssh_host_public_keys
                .into_iter()
                .map(NonEmptyString::into_inner)
                .collect(),
            relay_host_id: self.relay_host_id.map(NonEmptyString::into_inner),
            relay_capable: self.relay_capable,
            port: self.port,
            platform: self.platform,
            error_message: self.error_message.map(NonEmptyString::into_inner),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct PairingSessionResponse {
    pub session_id: String,
    pub pairing_code: String,
    pub qr_payload: String,
    pub host_token: String,
    pub expires_at_epoch_seconds: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct PairingSessionClaimResponse {
    pub session_id: String,
    pub expires_at_epoch_seconds: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct PairingSessionStatusResponse {
    pub session_id: String,
    pub status: PairingSessionStatus,
    pub expires_at_epoch_seconds: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub claimed_at_epoch_seconds: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completed_at_epoch_seconds: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completion: Option<PairingCompletionPayload>,
}

#[derive(Debug, Clone, Serialize)]
pub struct PairingSessionHostStatusResponse {
    pub session_id: String,
    pub status: PairingSessionStatus,
    pub expires_at_epoch_seconds: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub claimed_at_epoch_seconds: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completed_at_epoch_seconds: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub public_key: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub connector_bootstrap: Option<ConnectorBootstrapPayload>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completion: Option<PairingCompletionPayload>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PairingCompletionPayload {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detected_username: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub detected_username_source: Option<PairingDetectedUsernameSource>,
    #[serde(default)]
    pub detected_username_suspicious: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub host_candidates: Vec<PairingHostCandidate>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub host_environment_flags: Vec<PairingHostEnvironmentFlag>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub hostname_candidates: Vec<String>,
    #[serde(default)]
    pub uses_tailscale: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub ssh_host_public_keys: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub relay_host_id: Option<String>,
    #[serde(default)]
    pub relay_capable: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub port: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub platform: Option<PairingPlatform>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_message: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PairingDetectedUsernameSource {
    AccountLookup,
    IdCommand,
    EnvUser,
    WhoamiCommand,
}

impl PairingDetectedUsernameSource {
    pub fn is_legacy_ios_supported(self) -> bool {
        matches!(self, Self::IdCommand | Self::EnvUser)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PairingHostEnvironmentFlag {
    Container,
    Wsl,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PairingHostCandidateKind {
    TailscaleShort,
    TailscaleFqdn,
    Fqdn,
    SingleLabel,
    LocalDomain,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PairingHostCandidateSource {
    ScutilHostname,
    ScutilLocalhostname,
    HostnameFqdn,
    Hostname,
    OsHostname,
    EnvHostname,
    TailscaleShort,
    TailscaleMagicdns,
    LegacyHostnameCandidates,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PairingHostCandidateInput {
    pub value: NonEmptyString,
    pub kind: PairingHostCandidateKind,
    pub source: Option<PairingHostCandidateSource>,
    pub rank: u16,
}

impl PairingHostCandidateInput {
    fn into_candidate(self) -> PairingHostCandidate {
        PairingHostCandidate {
            value: self.value.into_inner(),
            kind: self.kind,
            source: self.source,
            rank: self.rank,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PairingHostCandidate {
    pub value: String,
    pub kind: PairingHostCandidateKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<PairingHostCandidateSource>,
    pub rank: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PairingPlatform {
    Macos,
    Linux,
}

impl PairingPlatform {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Macos => "macos",
            Self::Linux => "linux",
        }
    }
}

fn legacy_pairing_host_candidates(hostname_candidates: &[String]) -> Vec<PairingHostCandidate> {
    let tailscale_short_hostnames = hostname_candidates
        .iter()
        .filter_map(|candidate| tailscale_short_hostname(candidate))
        .map(|value| value.to_ascii_lowercase())
        .collect::<std::collections::HashSet<_>>();

    hostname_candidates
        .iter()
        .enumerate()
        .map(|(index, value)| PairingHostCandidate {
            value: value.clone(),
            kind: classify_legacy_pairing_host_candidate(value, &tailscale_short_hostnames),
            source: Some(PairingHostCandidateSource::LegacyHostnameCandidates),
            rank: u16::try_from(index + 1).unwrap_or(u16::MAX),
        })
        .collect()
}

fn classify_legacy_pairing_host_candidate(
    value: &str,
    tailscale_short_hostnames: &std::collections::HashSet<String>,
) -> PairingHostCandidateKind {
    let normalized = value.trim().to_ascii_lowercase();
    if tailscale_short_hostnames.contains(&normalized) {
        return PairingHostCandidateKind::TailscaleShort;
    }
    if normalized.ends_with(".ts.net") && normalized.contains('.') {
        return PairingHostCandidateKind::TailscaleFqdn;
    }
    if normalized.ends_with(".local") || normalized.ends_with(".localdomain") {
        return PairingHostCandidateKind::LocalDomain;
    }
    if normalized.contains('.') {
        return PairingHostCandidateKind::Fqdn;
    }
    PairingHostCandidateKind::SingleLabel
}

fn tailscale_short_hostname(value: &str) -> Option<&str> {
    let normalized = value.trim();
    let lower = normalized.to_ascii_lowercase();
    if !(lower.ends_with(".ts.net") && lower.contains('.')) {
        return None;
    }
    normalized
        .split('.')
        .next()
        .filter(|candidate| !candidate.is_empty())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum PairingSessionStatus {
    Pending,
    Claimed,
    Completed,
    Failed,
    Expired,
}

impl PairingSessionStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Claimed => "claimed",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::Expired => "expired",
        }
    }
}

impl fmt::Display for PairingSessionStatus {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

impl FromStr for PairingSessionStatus {
    type Err = ParsePairingSessionStatusError;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "pending" => Ok(Self::Pending),
            "claimed" => Ok(Self::Claimed),
            "completed" => Ok(Self::Completed),
            "failed" => Ok(Self::Failed),
            "expired" => Ok(Self::Expired),
            _ => Err(ParsePairingSessionStatusError),
        }
    }
}

#[derive(Debug, Clone)]
pub struct PairingSessionRecord {
    pub session_id: String,
    pub public_key: Option<String>,
    pub status: PairingSessionStatus,
    pub expires_at_epoch_seconds: i64,
    pub claimed_at_epoch_seconds: Option<i64>,
    pub completed_at_epoch_seconds: Option<i64>,
    pub completion: Option<PairingCompletionPayload>,
}

impl From<PairingSessionRecord> for PairingSessionStatusResponse {
    fn from(record: PairingSessionRecord) -> Self {
        Self {
            session_id: record.session_id,
            status: record.status,
            expires_at_epoch_seconds: record.expires_at_epoch_seconds,
            claimed_at_epoch_seconds: record.claimed_at_epoch_seconds,
            completed_at_epoch_seconds: record.completed_at_epoch_seconds,
            completion: record.completion,
        }
    }
}

impl From<PairingSessionRecord> for PairingSessionHostStatusResponse {
    fn from(record: PairingSessionRecord) -> Self {
        Self {
            session_id: record.session_id,
            status: record.status,
            expires_at_epoch_seconds: record.expires_at_epoch_seconds,
            claimed_at_epoch_seconds: record.claimed_at_epoch_seconds,
            completed_at_epoch_seconds: record.completed_at_epoch_seconds,
            public_key: record.public_key,
            connector_bootstrap: None,
            completion: record.completion,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConnectorRegisterRequest {
    pub bootstrap_token: NonEmptyString,
    pub existing_connector_id: Option<NonEmptyString>,
    pub existing_connector_secret: Option<NonEmptyString>,
    pub machine_id: NonEmptyString,
    pub ssh_username: NonEmptyString,
    pub platform: PairingPlatform,
    pub port: u16,
}

#[derive(Debug, Clone, Serialize)]
pub struct ConnectorRegisterResponse {
    pub connector_id: String,
    pub connector_secret: String,
    pub relay_host_id: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ConnectorSessionTokenRequest {
    pub connector_id: NonEmptyString,
    pub connector_secret: NonEmptyString,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SshRelaySessionCreateRequest {
    pub device_id: DeviceId,
    pub device_secret: NonEmptyString,
    pub relay_host_id: NonEmptyString,
}

#[derive(Debug, Clone, Serialize)]
pub struct ConnectorSessionTokenResponse {
    pub expires_at_epoch_seconds: i64,
    pub authorization_token: String,
    pub websocket_url: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct SshRelaySessionCreateResponse {
    pub relay_session_id: String,
    pub expires_at_epoch_seconds: i64,
    pub authorization_token: String,
    pub websocket_url: String,
}

#[derive(Debug, Clone)]
pub struct ConnectorRegistrationRecord {
    pub connector_id: String,
    pub connector_secret: String,
    pub relay_host_id: String,
}

#[derive(Debug, Clone)]
pub struct ConnectorAuthRecord {
    pub connector_id: String,
    pub relay_host_id: String,
}

#[derive(Debug, Clone)]
pub struct SshRelaySessionRecord {
    pub relay_host_id: String,
    pub relay_session_id: String,
    pub device_id: String,
    pub expires_at_epoch_seconds: i64,
}

pub fn generate_pairing_session_id() -> String {
    let mut bytes = [0_u8; 16];
    OsRng.fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

pub fn generate_pairing_code() -> String {
    let mut bytes = [0_u8; 8];
    OsRng.fill_bytes(&mut bytes);

    let characters = bytes
        .iter()
        .map(|byte| PAIRING_CODE_ALPHABET[(byte % 32) as usize] as char)
        .collect::<Vec<_>>();

    format!(
        "{}{}{}{}-{}{}{}{}",
        characters[0],
        characters[1],
        characters[2],
        characters[3],
        characters[4],
        characters[5],
        characters[6],
        characters[7]
    )
}

pub fn generate_pairing_host_token() -> String {
    let mut bytes = [0_u8; 32];
    OsRng.fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

pub fn normalize_pairing_code(value: &str) -> Option<String> {
    let normalized = value
        .chars()
        .filter(|character| character.is_ascii_alphanumeric())
        .map(|character| character.to_ascii_uppercase())
        .collect::<String>();

    if normalized.len() != 8 {
        return None;
    }

    Some(format!("{}-{}", &normalized[..4], &normalized[4..]))
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NotifyRequest {
    #[serde(default)]
    pub attempt_id: AttemptId,
    pub source: NonEmptyString,
    pub title: NonEmptyString,
    pub body: NonEmptyString,
    pub tmux_window_id: Option<i32>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InternalAlertRequest {
    pub topic: NonEmptyString,
    pub push_environment: PushEnvironment,
    pub device_token: NonEmptyString,
    pub title: NonEmptyString,
    pub body: NonEmptyString,
    pub subtitle: Option<NonEmptyString>,
    pub sound: Option<NonEmptyString>,
    pub collapse_id: Option<NonEmptyString>,
    pub mutable_content: bool,
    pub custom_data: Option<Map<String, Value>>,
}

impl InternalAlertRequest {
    pub fn validate(&self) -> Result<(), InternalRequestValidationError> {
        if self
            .custom_data
            .as_ref()
            .is_some_and(|value| value.contains_key("aps"))
        {
            return Err(InternalRequestValidationError::ReservedApsPayloadKey);
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LiveActivityEvent {
    Update,
    End,
}

impl LiveActivityEvent {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Update => "update",
            Self::End => "end",
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InternalLiveActivityAlert {
    pub title: NonEmptyString,
    pub body: NonEmptyString,
    pub subtitle: Option<NonEmptyString>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InternalLiveActivityRequest {
    pub bundle_id: NonEmptyString,
    pub push_environment: PushEnvironment,
    pub device_token: NonEmptyString,
    pub event: LiveActivityEvent,
    pub timestamp: i64,
    pub content_state: Value,
    pub stale_date: Option<i64>,
    pub dismissal_date: Option<i64>,
    pub alert: Option<InternalLiveActivityAlert>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InternalLocationRequest {
    pub bundle_id: NonEmptyString,
    pub push_environment: PushEnvironment,
    pub device_token: NonEmptyString,
    pub expiration: i64,
    pub custom_data: Map<String, Value>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InternalVoipRequest {
    pub bundle_id: NonEmptyString,
    pub push_environment: PushEnvironment,
    pub device_token: NonEmptyString,
    pub call_id: NonEmptyString,
    pub host_id: NonEmptyString,
    pub expires_at: i64,
}

impl InternalVoipRequest {
    pub fn validate(&self) -> Result<(), InternalRequestValidationError> {
        for id in [&self.call_id, &self.host_id] {
            let bytes = id.as_str().as_bytes();
            if bytes.len() != 36
                || !bytes.iter().enumerate().all(|(index, byte)| {
                    if matches!(index, 8 | 13 | 18 | 23) {
                        *byte == b'-'
                    } else {
                        byte.is_ascii_hexdigit()
                    }
                })
            {
                return Err(InternalRequestValidationError::InvalidCallIdentity);
            }
        }
        if self.expires_at <= 0 {
            return Err(InternalRequestValidationError::NonPositiveTimestamp(
                TimestampField::ExpiresAt,
            ));
        }
        Ok(())
    }
}

impl InternalLocationRequest {
    pub fn validate(&self) -> Result<(), InternalRequestValidationError> {
        if self.expiration <= 0 {
            return Err(InternalRequestValidationError::NonPositiveTimestamp(
                TimestampField::Expiration,
            ));
        }
        if self.custom_data.contains_key("aps") {
            return Err(InternalRequestValidationError::ReservedApsPayloadKey);
        }
        Ok(())
    }

    pub fn topic(&self) -> String {
        format!("{}.location-query", self.bundle_id)
    }
}

impl InternalLiveActivityRequest {
    pub fn validate(&self) -> Result<(), InternalRequestValidationError> {
        if self.timestamp <= 0 {
            return Err(InternalRequestValidationError::NonPositiveTimestamp(
                TimestampField::Timestamp,
            ));
        }
        if let Some(stale_date) = self.stale_date
            && stale_date <= 0
        {
            return Err(InternalRequestValidationError::NonPositiveTimestamp(
                TimestampField::StaleDate,
            ));
        }
        if let Some(dismissal_date) = self.dismissal_date
            && dismissal_date <= 0
        {
            return Err(InternalRequestValidationError::NonPositiveTimestamp(
                TimestampField::DismissalDate,
            ));
        }
        if !self.content_state.is_object() {
            return Err(InternalRequestValidationError::ContentStateMustBeObject);
        }
        Ok(())
    }

    pub fn live_activity_topic(&self) -> String {
        format!("{}.push-type.liveactivity", self.bundle_id)
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct BrokerSendResponse {
    pub status: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub apns_id: Option<String>,
    pub push_environment: PushEnvironment,
    pub push_type: PushType,
    pub topic: String,
}

#[derive(Debug, Clone)]
pub struct DeviceRecord {
    pub device_id: String,
    pub apns_token: String,
    pub bundle_id: String,
    pub push_environment: PushEnvironment,
}

#[must_use]
pub(crate) fn normalize_device_id(value: &str) -> String {
    value.to_ascii_lowercase()
}

fn validate_bundle_environment_pair(
    bundle_id: &str,
    push_environment: PushEnvironment,
) -> Result<(), BundleEnvironmentError> {
    if bundle_id == MAIN_BUNDLE_ID {
        if push_environment == PushEnvironment::Production {
            return Ok(());
        }
        return Err(BundleEnvironmentError);
    }

    let Some(suffix) = bundle_id.strip_prefix(MAIN_BUNDLE_ID) else {
        return Err(BundleEnvironmentError);
    };
    if DEVELOPMENT_BUNDLE_SUFFIXES.contains(&suffix)
        && push_environment == PushEnvironment::Development
    {
        Ok(())
    } else {
        Err(BundleEnvironmentError)
    }
}

#[derive(Debug, Error)]
#[error("unsupported bundle/environment pair")]
pub struct BundleEnvironmentError;

#[derive(Debug, Error)]
#[error("string must not be empty")]
pub struct EmptyStringError;

#[derive(Debug, Error)]
#[error("invalid push environment")]
pub struct ParsePushEnvironmentError;

#[derive(Debug, Error)]
#[error("invalid pairing session status")]
pub struct ParsePairingSessionStatusError;

#[derive(Debug, Error)]
pub enum AnalyticsValidationError {
    #[error("Analytics batch must contain at least one event.")]
    EmptyEventBatch,
    #[error("original_purchase_date_epoch_seconds must be positive.")]
    NonPositiveOriginalPurchaseDate,
    #[error("Analytics ingestion requires the main production bundle.")]
    UnsupportedBundle,
    #[error("Analytics ingestion requires the main flavor.")]
    UnsupportedFlavor,
    #[error("Analytics event timestamps must be positive.")]
    NonPositiveEventTimestamp,
    #[error("Unsupported analytics payload_version {0}.")]
    UnsupportedPayloadVersion(u8),
    #[error("Analytics event payloads must be JSON objects.")]
    PayloadMustBeObject,
    #[error("Analytics access-state payload is invalid.")]
    InvalidAccessStatePayload,
    #[error("Analytics app-session payload is invalid.")]
    InvalidAppSessionPayload,
    #[error("Analytics access-state snapshot payload is invalid.")]
    InvalidAccessStateSnapshotPayload,
    #[error("Analytics SSH session payload is invalid.")]
    InvalidSshSessionPayload,
    #[error("Analytics purchase-flow payload is invalid.")]
    InvalidPurchaseFlowPayload,
    #[error("Analytics host-setup payload is invalid.")]
    InvalidHostSetupPayload {
        field: &'static str,
        rule: &'static str,
    },
    #[error("Analytics paywall payload is invalid.")]
    InvalidPaywallPayload,
    #[error("Analytics key-material payload is invalid.")]
    InvalidKeyMaterialPayload,
}

impl AnalyticsValidationError {
    pub fn is_event_scoped(&self) -> bool {
        matches!(
            self,
            Self::NonPositiveEventTimestamp
                | Self::UnsupportedPayloadVersion(_)
                | Self::PayloadMustBeObject
                | Self::InvalidAccessStatePayload
                | Self::InvalidAppSessionPayload
                | Self::InvalidAccessStateSnapshotPayload
                | Self::InvalidSshSessionPayload
                | Self::InvalidPurchaseFlowPayload
                | Self::InvalidHostSetupPayload { .. }
                | Self::InvalidPaywallPayload
                | Self::InvalidKeyMaterialPayload
        )
    }

    pub fn field(&self) -> Option<&'static str> {
        match self {
            Self::InvalidHostSetupPayload { field, .. } => Some(field),
            _ => None,
        }
    }

    pub fn rule(&self) -> Option<&'static str> {
        match self {
            Self::InvalidHostSetupPayload { rule, .. } => Some(rule),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_pairing_candidates_are_classified_and_ranked() {
        let candidates = legacy_pairing_host_candidates(&[
            "host.tail123.ts.net".to_owned(),
            "host".to_owned(),
            "host.localdomain".to_owned(),
        ]);

        assert_eq!(candidates[0].kind, PairingHostCandidateKind::TailscaleFqdn);
        assert_eq!(candidates[1].kind, PairingHostCandidateKind::TailscaleShort);
        assert_eq!(candidates[2].kind, PairingHostCandidateKind::LocalDomain);
        assert_eq!(candidates[0].rank, 1);
        assert_eq!(candidates[2].rank, 3);
    }

    #[test]
    fn analytics_host_setup_payload_rejects_nonpositive_probe_attempt_count() {
        let payload = AnalyticsHostSetupFlowPayload {
            app_session_id: None,
            flow_id: None,
            method: AnalyticsHostSetupMethod::Automatic,
            stage: AnalyticsHostSetupStage::Failed,
            is_edit: false,
            uses_tailscale_address: false,
            saved_host_count: None,
            host_id_hash: None,
            error_category: Some(AnalyticsHostSetupErrorCategory::Reachability),
            error_message: None,
            detected_username: None,
            detected_username_source: None,
            username_suspicious: None,
            host_edited: Some(true),
            port_edited: Some(false),
            username_edited: Some(false),
            selected_candidate_kind: Some(AnalyticsHostCandidateKind::SingleLabel),
            selected_candidate_source: None,
            selected_candidate_rank: None,
            selected_candidate_value: None,
            candidate_values: Vec::new(),
            candidate_count: None,
            high_confidence_candidate_count: None,
            all_low_confidence_candidates: None,
            host_platform: None,
            host_environment_flags: Vec::new(),
            probe_attempt_count: Some(0),
            reachability_failure_subtype: Some(AnalyticsReachabilityFailureSubtype::Dns),
            verification_attempt_count: None,
            verification_failure_stage: None,
            verification_disconnect_category: None,
        };

        assert!(matches!(
            payload.validate(),
            Err(AnalyticsValidationError::InvalidHostSetupPayload {
                field: "reachability.attempt_count",
                rule: "positive"
            })
        ));
    }

    #[test]
    fn analytics_host_setup_payload_rejects_inconsistent_candidate_counts() {
        let payload = AnalyticsHostSetupFlowPayload {
            app_session_id: None,
            flow_id: Some(NonEmptyString::new("flow-1".to_owned()).unwrap()),
            method: AnalyticsHostSetupMethod::Automatic,
            stage: AnalyticsHostSetupStage::ReviewPresented,
            is_edit: false,
            uses_tailscale_address: false,
            saved_host_count: None,
            host_id_hash: None,
            error_category: None,
            error_message: None,
            detected_username: None,
            detected_username_source: None,
            username_suspicious: Some(false),
            host_edited: Some(false),
            port_edited: Some(false),
            username_edited: Some(false),
            selected_candidate_kind: Some(AnalyticsHostCandidateKind::Fqdn),
            selected_candidate_source: Some(AnalyticsHostCandidateSource::HostnameFqdn),
            selected_candidate_rank: Some(2),
            selected_candidate_value: Some(NonEmptyString::new("host.local".to_owned()).unwrap()),
            candidate_values: vec![NonEmptyString::new("host.local".to_owned()).unwrap()],
            candidate_count: Some(2),
            high_confidence_candidate_count: Some(1),
            all_low_confidence_candidates: Some(false),
            host_platform: Some(AnalyticsHostPlatform::Linux),
            host_environment_flags: Vec::new(),
            probe_attempt_count: None,
            reachability_failure_subtype: None,
            verification_attempt_count: None,
            verification_failure_stage: None,
            verification_disconnect_category: None,
        };

        assert!(matches!(
            payload.validate(),
            Err(AnalyticsValidationError::InvalidHostSetupPayload {
                field: "candidates.count",
                rule: "matches_all_values_count"
            })
        ));
    }

    #[test]
    fn analytics_host_setup_payload_requires_structured_verification_fields_on_verification_failure()
     {
        let valid_payload = AnalyticsHostSetupFlowPayload {
            app_session_id: None,
            flow_id: Some(NonEmptyString::new("flow-verify-1".to_owned()).unwrap()),
            method: AnalyticsHostSetupMethod::Automatic,
            stage: AnalyticsHostSetupStage::VerificationFailed,
            is_edit: false,
            uses_tailscale_address: false,
            saved_host_count: None,
            host_id_hash: None,
            error_category: Some(AnalyticsHostSetupErrorCategory::ConnectionVerification),
            error_message: Some(NonEmptyString::new("auth failed".to_owned()).unwrap()),
            detected_username: None,
            detected_username_source: None,
            username_suspicious: None,
            host_edited: None,
            port_edited: None,
            username_edited: None,
            selected_candidate_kind: None,
            selected_candidate_source: None,
            selected_candidate_rank: None,
            selected_candidate_value: None,
            candidate_values: Vec::new(),
            candidate_count: None,
            high_confidence_candidate_count: None,
            all_low_confidence_candidates: None,
            host_platform: None,
            host_environment_flags: Vec::new(),
            probe_attempt_count: None,
            reachability_failure_subtype: None,
            verification_attempt_count: Some(2),
            verification_failure_stage: Some(AnalyticsSshFailureStage::SshAuth),
            verification_disconnect_category: Some(AnalyticsSshDisconnectCategory::AuthFailed),
        };
        assert!(valid_payload.validate().is_ok());

        let invalid_payload = AnalyticsHostSetupFlowPayload {
            verification_disconnect_category: None,
            ..valid_payload
        };
        assert!(matches!(
            invalid_payload.validate(),
            Err(AnalyticsValidationError::InvalidHostSetupPayload {
                field: "verification",
                rule: "failure_requires_stage_and_disconnect_category"
            })
        ));
    }

    #[test]
    fn analytics_host_setup_payload_requires_structured_verification_fields_on_unverified_save() {
        let valid_payload = AnalyticsHostSetupFlowPayload {
            app_session_id: None,
            flow_id: Some(NonEmptyString::new("flow-verify-save".to_owned()).unwrap()),
            method: AnalyticsHostSetupMethod::Manual,
            stage: AnalyticsHostSetupStage::SaveSucceededUnverified,
            is_edit: false,
            uses_tailscale_address: false,
            saved_host_count: Some(1),
            host_id_hash: Some(
                NonEmptyString::new(
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".to_owned(),
                )
                .unwrap(),
            ),
            error_category: None,
            error_message: None,
            detected_username: None,
            detected_username_source: None,
            username_suspicious: None,
            host_edited: None,
            port_edited: None,
            username_edited: None,
            selected_candidate_kind: None,
            selected_candidate_source: None,
            selected_candidate_rank: None,
            selected_candidate_value: None,
            candidate_values: Vec::new(),
            candidate_count: None,
            high_confidence_candidate_count: None,
            all_low_confidence_candidates: None,
            host_platform: None,
            host_environment_flags: Vec::new(),
            probe_attempt_count: None,
            reachability_failure_subtype: None,
            verification_attempt_count: Some(1),
            verification_failure_stage: Some(AnalyticsSshFailureStage::SshAuth),
            verification_disconnect_category: Some(AnalyticsSshDisconnectCategory::AuthFailed),
        };
        assert!(valid_payload.validate().is_ok());

        let invalid_payload = AnalyticsHostSetupFlowPayload {
            verification_failure_stage: None,
            ..valid_payload
        };
        assert!(matches!(
            invalid_payload.validate(),
            Err(AnalyticsValidationError::InvalidHostSetupPayload {
                field: "verification",
                rule: "failure_requires_stage_and_disconnect_category"
            })
        ));
    }

    #[test]
    fn analytics_key_material_payload_requires_failure_reason_only_for_failed_stage() {
        let failed_without_reason = AnalyticsKeyMaterialPayload {
            app_session_id: None,
            operation: AnalyticsKeyMaterialOperation::Import,
            stage: AnalyticsKeyMaterialStage::Failed,
            key_type: None,
            failure_reason: None,
            failure_detail: Some(NonEmptyString::new("boom".to_owned()).unwrap()),
        };
        assert!(matches!(
            failed_without_reason.validate(),
            Err(AnalyticsValidationError::InvalidKeyMaterialPayload)
        ));

        let succeeded_with_reason = AnalyticsKeyMaterialPayload {
            app_session_id: None,
            operation: AnalyticsKeyMaterialOperation::Generate,
            stage: AnalyticsKeyMaterialStage::Succeeded,
            key_type: Some(NonEmptyString::new("ed25519".to_owned()).unwrap()),
            failure_reason: Some(AnalyticsKeyMaterialFailureReason::InternalError),
            failure_detail: None,
        };
        assert!(matches!(
            succeeded_with_reason.validate(),
            Err(AnalyticsValidationError::InvalidKeyMaterialPayload)
        ));
    }

    #[test]
    fn ssh_relay_session_create_response_serializes_expected_contract_keys() {
        let payload = SshRelaySessionCreateResponse {
            relay_session_id: "relay-session-1".to_owned(),
            expires_at_epoch_seconds: 123,
            authorization_token: "relay-token-1".to_owned(),
            websocket_url: "wss://agentty.esmadil.se/v1/ssh-relay-sessions/relay-session-1/ws"
                .to_owned(),
        };

        let encoded = serde_json::to_value(payload).expect("serialize ssh relay response");

        assert_eq!(encoded["relay_session_id"], "relay-session-1");
        assert_eq!(encoded["expires_at_epoch_seconds"], 123);
        assert_eq!(encoded["authorization_token"], "relay-token-1");
        assert_eq!(
            encoded["websocket_url"],
            "wss://agentty.esmadil.se/v1/ssh-relay-sessions/relay-session-1/ws"
        );
        assert!(encoded.get("relaySessionId").is_none());
        assert!(encoded.get("websocketUrl").is_none());
    }
}

#[derive(Debug, Error)]
pub enum InternalRequestValidationError {
    #[error("call_id and host_id must be UUIDs")]
    InvalidCallIdentity,
    #[error("custom_data may not contain reserved key aps")]
    ReservedApsPayloadKey,
    #[error("{0} must be positive")]
    NonPositiveTimestamp(TimestampField),
    #[error("content_state must be a JSON object")]
    ContentStateMustBeObject,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TimestampField {
    ExpiresAt,
    Expiration,
    Timestamp,
    StaleDate,
    DismissalDate,
}

impl fmt::Display for TimestampField {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::ExpiresAt => "expires_at",
            Self::Expiration => "expiration",
            Self::Timestamp => "timestamp",
            Self::StaleDate => "stale_date",
            Self::DismissalDate => "dismissal_date",
        })
    }
}
