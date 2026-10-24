#![forbid(unsafe_code)]

pub mod admission;
pub mod api;
pub mod apns;
mod app_transaction;
pub mod build_info;
pub mod config;
pub mod dictation;
pub mod error;
pub mod logging;
pub mod models;
pub mod relay_broker;
pub mod relay_tokens;
pub mod storage;

use std::sync::Arc;

use anyhow::Result;
use axum::Router;

use crate::api::build_router;
use crate::apns::ApnsPushSender;
use crate::config::{AnalyticsAlertSettings, InternalClientSettings, Settings};
use crate::dictation::{
    DictationTranscriber, NoopDictationTranscriber, OpenAIDictationTranscriber,
};
use crate::relay_broker::RelayBroker;
use crate::relay_tokens::RelayTokenManager;
use crate::storage::Database;

#[derive(Clone)]
pub struct AppState {
    pub database: Database,
    pub push_sender: Arc<dyn apns::PushSender>,
    pub dictation_transcriber: Arc<dyn DictationTranscriber>,
    pub internal_clients: Arc<Vec<InternalClientSettings>>,
    pub analytics_alerts: Arc<AnalyticsAlertSettings>,
    pub relay_broker: RelayBroker,
    pub relay_tokens: Arc<RelayTokenManager>,
    pub admission: Arc<admission::Admission>,
}

pub async fn create_app(settings: Settings, relay_broker: RelayBroker) -> Result<Router> {
    let database = Database::open(settings.database_path.clone()).await?;
    let push_sender = Arc::new(ApnsPushSender::new(&settings)?);
    let dictation_transcriber = Arc::new(OpenAIDictationTranscriber::new(&settings)?);
    let relay_tokens = Arc::new(RelayTokenManager::from_settings(&settings)?);

    Ok(build_router(AppState {
        admission: Arc::new(admission::Admission::new(settings.dictation_limits)),
        database,
        push_sender,
        dictation_transcriber,
        internal_clients: Arc::new(settings.internal_clients),
        analytics_alerts: Arc::new(settings.analytics_alerts),
        relay_broker,
        relay_tokens,
    }))
}

pub fn create_test_app(
    database: Database,
    push_sender: Arc<dyn apns::PushSender>,
    internal_clients: Vec<InternalClientSettings>,
    limits: config::DictationLimits,
) -> Router {
    create_test_app_with_transcriber(
        database,
        push_sender,
        Arc::new(NoopDictationTranscriber),
        internal_clients,
        limits,
    )
}

pub fn create_test_app_with_transcriber(
    database: Database,
    push_sender: Arc<dyn apns::PushSender>,
    dictation_transcriber: Arc<dyn DictationTranscriber>,
    internal_clients: Vec<InternalClientSettings>,
    limits: config::DictationLimits,
) -> Router {
    build_router(AppState {
        admission: Arc::new(admission::Admission::new(limits)),
        database,
        push_sender,
        dictation_transcriber,
        internal_clients: Arc::new(internal_clients),
        analytics_alerts: Arc::new(AnalyticsAlertSettings {
            destination_device_id: None,
            cooldown_seconds: 6 * 60 * 60,
            internal_device_ids: Vec::new(),
            internal_user_key_hashes: Vec::new(),
        }),
        relay_broker: RelayBroker::default(),
        relay_tokens: Arc::new(
            RelayTokenManager::for_test("https://agentty-notify.test")
                .expect("test relay token manager"),
        ),
    })
}
