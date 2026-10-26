use std::io;
use std::pin::Pin;
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail, ensure};
use async_trait::async_trait;
use axum::body::Bytes;
use base64::Engine;
use futures_util::{Stream, StreamExt, stream};
use reqwest::{Body, Client, StatusCode, header};
use serde::{Deserialize, Serialize};
use thiserror::Error;

use crate::config::{DictationLimits, Settings};

pub const AZURE_SPEECH_API_VERSION: &str = "2025-10-15";
pub const STREAM_SAMPLE_RATE: u32 = 16_000;
pub const STREAM_BYTES_PER_SECOND: u64 = STREAM_SAMPLE_RATE as u64 * 2;
pub const WAV_HEADER_BYTES: usize = 44;
const MAI_TRANSCRIBE_MODEL: &str = "MAI-Transcribe-2";
const MAX_UPSTREAM_RESPONSE_BYTES: usize = 1024 * 1024;

pub type AudioStream = Pin<Box<dyn Stream<Item = io::Result<Bytes>> + Send>>;

pub struct SpeechUpload {
    pub definition: Definition,
    pub wav: AudioStream,
}

pub struct SpeechResponse {
    pub status: StatusCode,
    pub body: Bytes,
}

#[derive(Debug, Error)]
#[error("speech upstream unavailable")]
pub struct SpeechUpstreamUnavailable(#[source] pub anyhow::Error);

#[async_trait]
pub trait SpeechUpstream: Send + Sync {
    async fn transcribe(
        &self,
        upload: SpeechUpload,
    ) -> std::result::Result<SpeechResponse, SpeechUpstreamUnavailable>;
}

pub struct RouterSpeechUpstream {
    client: Client,
    url: String,
    key: String,
}

impl RouterSpeechUpstream {
    pub fn new(settings: &Settings) -> Result<Self> {
        Ok(Self {
            client: Client::builder()
                .connect_timeout(Duration::from_secs(10))
                .build()
                .context("failed to build speech upstream client")?,
            url: format!(
                "{}/vendors/azure-speech/speechtotext/transcriptions:transcribe?api-version={AZURE_SPEECH_API_VERSION}",
                settings.llm_router_url
            ),
            key: settings.llm_router_key.clone(),
        })
    }
}

#[async_trait]
impl SpeechUpstream for RouterSpeechUpstream {
    async fn transcribe(
        &self,
        upload: SpeechUpload,
    ) -> std::result::Result<SpeechResponse, SpeechUpstreamUnavailable> {
        let unavailable = |error: reqwest::Error| SpeechUpstreamUnavailable(error.into());
        let boundary = hex::encode(rand::random::<[u8; 16]>());
        let definition = serde_json::to_string(&upload.definition)
            .map_err(|error| SpeechUpstreamUnavailable(error.into()))?;
        let prefix = Bytes::from(format!(
            "--{boundary}\r\nContent-Disposition: form-data; name=\"definition\"\r\n\r\n{definition}\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n"
        ));
        let suffix = Bytes::from(format!("\r\n--{boundary}--\r\n"));
        let body = stream::once(async { Ok(prefix) })
            .chain(upload.wav)
            .chain(stream::once(async { Ok(suffix) }));
        let mut response = self
            .client
            .post(&self.url)
            .bearer_auth(&self.key)
            .header(
                header::CONTENT_TYPE,
                format!("multipart/form-data; boundary={boundary}"),
            )
            .body(Body::wrap_stream(body))
            .send()
            .await
            .map_err(unavailable)?;
        let status = response.status();
        let mut body = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(unavailable)? {
            if body.len() + chunk.len() > MAX_UPSTREAM_RESPONSE_BYTES {
                return Err(SpeechUpstreamUnavailable(anyhow!(
                    "speech response exceeds limit"
                )));
            }
            body.extend_from_slice(&chunk);
        }
        Ok(SpeechResponse {
            status,
            body: body.into(),
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Definition {
    enhanced_mode: EnhancedMode,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    phrase_list: Option<PhraseList>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    locales: Option<Vec<String>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct EnhancedMode {
    enabled: bool,
    model: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    model_options: Option<ModelOptions>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct ModelOptions {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    transcribe_style: Option<TranscribeStyle>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
enum TranscribeStyle {
    Clean,
    Verbatim,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct PhraseList {
    phrases: Vec<String>,
}

impl Definition {
    pub fn clean_transcript() -> Self {
        Self {
            enhanced_mode: EnhancedMode {
                enabled: true,
                model: MAI_TRANSCRIBE_MODEL.to_owned(),
                model_options: Some(ModelOptions {
                    transcribe_style: Some(TranscribeStyle::Clean),
                }),
            },
            phrase_list: None,
            locales: None,
        }
    }

    pub fn parse(json: &[u8]) -> Result<Self> {
        let definition: Self = serde_json::from_slice(json)?;
        ensure!(
            definition.enhanced_mode.enabled
                && definition.enhanced_mode.model == MAI_TRANSCRIBE_MODEL,
            "unsupported transcription model"
        );
        if let Some(list) = &definition.phrase_list {
            ensure!(
                list.phrases.len() <= 50
                    && list
                        .phrases
                        .iter()
                        .all(|phrase| (1..=50).contains(&phrase.chars().count())),
                "invalid phrase list"
            );
        }
        if let Some(locales) = &definition.locales {
            ensure!(
                locales.len() == 1
                    && locales.iter().all(|locale| {
                        (2..=16).contains(&locale.len())
                            && locale
                                .bytes()
                                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
                    }),
                "invalid locale"
            );
        }
        Ok(definition)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StreamWavLength {
    Open,
    Exact(u64),
}

pub fn parse_stream_wav_header(header: &[u8]) -> Result<StreamWavLength> {
    ensure!(header.len() == WAV_HEADER_BYTES, "incomplete wav header");
    let u32_at = |offset: usize| u32::from_le_bytes(header[offset..offset + 4].try_into().unwrap());
    let u16_at = |offset: usize| u16::from_le_bytes(header[offset..offset + 2].try_into().unwrap());
    ensure!(
        &header[0..4] == b"RIFF"
            && &header[8..16] == b"WAVEfmt "
            && u32_at(16) == 16
            && u16_at(20) == 1
            && u16_at(22) == 1
            && u32_at(24) == STREAM_SAMPLE_RATE
            && u64::from(u32_at(28)) == STREAM_BYTES_PER_SECOND
            && u16_at(32) == 2
            && u16_at(34) == 16
            && &header[36..40] == b"data",
        "unsupported wav format"
    );
    match (u32_at(4), u32_at(40)) {
        (u32::MAX, u32::MAX) => Ok(StreamWavLength::Open),
        (riff, data) if data > 0 && data % 2 == 0 && data.checked_add(36) == Some(riff) => {
            Ok(StreamWavLength::Exact(u64::from(data)))
        }
        _ => bail!("contradictory wav lengths"),
    }
}

pub fn open_stream_wav_header() -> Bytes {
    let mut header = Vec::with_capacity(WAV_HEADER_BYTES);
    header.extend_from_slice(b"RIFF");
    header.extend_from_slice(&u32::MAX.to_le_bytes());
    header.extend_from_slice(b"WAVEfmt ");
    header.extend_from_slice(&16_u32.to_le_bytes());
    header.extend_from_slice(&1_u16.to_le_bytes());
    header.extend_from_slice(&1_u16.to_le_bytes());
    header.extend_from_slice(&STREAM_SAMPLE_RATE.to_le_bytes());
    header.extend_from_slice(&(STREAM_BYTES_PER_SECOND as u32).to_le_bytes());
    header.extend_from_slice(&2_u16.to_le_bytes());
    header.extend_from_slice(&16_u16.to_le_bytes());
    header.extend_from_slice(b"data");
    header.extend_from_slice(&u32::MAX.to_le_bytes());
    header.into()
}

pub fn transcript_text(body: &[u8]) -> Result<String> {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Transcription {
        combined_phrases: Vec<Phrase>,
    }
    #[derive(Deserialize)]
    struct Phrase {
        text: String,
    }
    let transcription: Transcription = serde_json::from_slice(body)?;
    Ok(transcription
        .combined_phrases
        .into_iter()
        .map(|phrase| phrase.text)
        .collect::<Vec<_>>()
        .join("\n"))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DictationTier {
    Free,
    Lifetime,
}

impl DictationTier {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Free => "free",
            Self::Lifetime => "lifetime",
        }
    }

    pub fn from_stored(value: Option<&str>) -> Self {
        match value {
            Some("lifetime") => Self::Lifetime,
            _ => Self::Free,
        }
    }

    pub fn monthly_seconds(self, limits: &DictationLimits) -> i64 {
        match self {
            Self::Free => limits.free_monthly_seconds,
            Self::Lifetime => limits.lifetime_monthly_seconds,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DictationSubject {
    Ledger { hash: String, monthly_seconds: i64 },
    LegacyDevice(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DictationGrant {
    pub seconds: i64,
    pub remaining_seconds: i64,
    pub resets_at_epoch_seconds: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DictationQuotaExceeded {
    pub operator_limit: bool,
    pub remaining_seconds: i64,
    pub quota_resets_at_epoch_seconds: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DictationWindows {
    pub day: i64,
    pub week_start: i64,
    pub month_start: i64,
    pub next_month_start: i64,
}

impl DictationWindows {
    pub fn now() -> Self {
        Self::at(current_epoch_seconds())
    }

    pub fn at(epoch_seconds: i64) -> Self {
        const DAY: i64 = 24 * 60 * 60;
        let days = epoch_seconds.div_euclid(DAY);
        let (year, month) = civil_year_month(days);
        let (next_year, next_month) = if month == 12 {
            (year + 1, 1)
        } else {
            (year, month + 1)
        };
        Self {
            day: days,
            week_start: (days - (days + 3).rem_euclid(7)) * DAY,
            month_start: days_from_civil(year, month) * DAY,
            next_month_start: days_from_civil(next_year, next_month) * DAY,
        }
    }

    pub fn week_resets_at(&self) -> i64 {
        self.week_start + 7 * 24 * 60 * 60
    }
}

fn civil_year_month(days: i64) -> (i64, i64) {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let day_of_era = z.rem_euclid(146_097);
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let shifted_month = (5 * day_of_year + 2) / 153;
    let month = if shifted_month < 10 {
        shifted_month + 3
    } else {
        shifted_month - 9
    };
    (year_of_era + era * 400 + i64::from(month <= 2), month)
}

fn days_from_civil(year: i64, month: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let year_of_era = year.rem_euclid(400);
    let shifted_month = if month > 2 { month - 3 } else { month + 9 };
    let day_of_year = (153 * shifted_month + 2) / 5;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

pub fn parse_audio_payload(audio_base64: &str, mime_type: &str) -> Result<(Vec<u8>, i64)> {
    if mime_type != "audio/wav" {
        bail!("only audio/wav payloads are supported")
    }
    let audio_bytes = base64::engine::general_purpose::STANDARD
        .decode(audio_base64)
        .context("failed to decode base64 audio payload")?;
    let charged_seconds = parse_wav_duration_seconds(&audio_bytes)?;
    Ok((audio_bytes, charged_seconds))
}

fn parse_wav_duration_seconds(audio: &[u8]) -> Result<i64> {
    if audio.len() < 44 || audio.len() > 25_000_000 {
        bail!("wav payload length is outside supported bounds")
    }
    if &audio[..4] != b"RIFF" || &audio[8..12] != b"WAVE" {
        bail!("wav payload missing RIFF/WAVE header")
    }
    let read_u32 =
        |offset: usize| u32::from_le_bytes(audio[offset..offset + 4].try_into().unwrap());
    let read_u16 =
        |offset: usize| u16::from_le_bytes(audio[offset..offset + 2].try_into().unwrap());
    if read_u32(4) as usize != audio.len() - 8 {
        bail!("wav RIFF length contradicts payload")
    }
    let mut cursor = 12;
    let mut format = None;
    let mut data_size = None;
    while cursor < audio.len() {
        if audio.len() - cursor < 8 {
            bail!("truncated wav chunk header")
        }
        let id = &audio[cursor..cursor + 4];
        let size = read_u32(cursor + 4) as usize;
        cursor += 8;
        let end = cursor.checked_add(size).context("wav chunk overflow")?;
        if end > audio.len() {
            bail!("wav chunk exceeds payload")
        }
        match id {
            b"fmt " => {
                if format.is_some() || data_size.is_some() || !matches!(size, 16 | 18) {
                    bail!("unsupported or duplicate wav format")
                }
                let encoding = read_u16(cursor);
                let channels = read_u16(cursor + 2);
                let sample_rate = read_u32(cursor + 4);
                let byte_rate = read_u32(cursor + 8);
                let block_align = read_u16(cursor + 12);
                let bits = read_u16(cursor + 14);
                if encoding != 1
                    || !(1..=2).contains(&channels)
                    || !(8_000..=192_000).contains(&sample_rate)
                    || !matches!(bits, 8 | 16 | 24 | 32)
                    || block_align != channels * (bits / 8)
                    || byte_rate != sample_rate * u32::from(block_align)
                    || (size == 18 && read_u16(cursor + 16) != 0)
                {
                    bail!("contradictory or unsupported PCM format")
                }
                format = Some((sample_rate, block_align));
            }
            b"data" => {
                if data_size.is_some() || format.is_none() || size == 0 {
                    bail!("missing format, empty or duplicate wav data")
                }
                data_size = Some(size);
            }
            _ => bail!("unsupported wav chunk"),
        }
        cursor = end + size % 2;
        if cursor > audio.len() {
            bail!("wav chunk padding missing")
        }
    }
    let (sample_rate, block_align) = format.context("wav format missing")?;
    let data_size = data_size.context("wav data missing")?;
    if data_size % usize::from(block_align) != 0 {
        bail!("wav data contains a partial sample frame")
    }
    let frames = data_size / usize::from(block_align);
    let seconds = (frames as i64 + i64::from(sample_rate) - 1) / i64::from(sample_rate);
    ensure!(
        seconds <= 1800,
        "WAV duration exceeds the 30-minute request limit"
    );
    Ok(seconds)
}

fn current_epoch_seconds() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};

    match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(duration) => duration.as_secs() as i64,
        Err(_) => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;

    fn sample_wav(
        data_bytes: u32,
        sample_rate: u32,
        channels: u16,
        bits_per_sample: u16,
    ) -> Vec<u8> {
        let block_align = channels * (bits_per_sample / 8);
        let byte_rate = sample_rate * u32::from(block_align);
        let chunk_size = 36 + data_bytes;

        let mut wav = Vec::new();
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&chunk_size.to_le_bytes());
        wav.extend_from_slice(b"WAVE");
        wav.extend_from_slice(b"fmt ");
        wav.extend_from_slice(&16_u32.to_le_bytes());
        wav.extend_from_slice(&1_u16.to_le_bytes());
        wav.extend_from_slice(&channels.to_le_bytes());
        wav.extend_from_slice(&sample_rate.to_le_bytes());
        wav.extend_from_slice(&byte_rate.to_le_bytes());
        wav.extend_from_slice(&block_align.to_le_bytes());
        wav.extend_from_slice(&bits_per_sample.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&data_bytes.to_le_bytes());
        wav.resize(wav.len() + data_bytes as usize, 0);
        wav
    }

    #[test]
    fn wav_duration_rounds_up_to_next_second() {
        let wav = sample_wav(16_001 * 2, 16_000, 1, 16);
        let encoded = base64::engine::general_purpose::STANDARD.encode(wav);

        let (_, charged_seconds) = parse_audio_payload(&encoded, "audio/wav").unwrap();

        assert_eq!(charged_seconds, 2);
    }
    #[test]
    fn rejects_forged_or_ambiguous_pcm_headers() {
        let valid = sample_wav(16_000 * 2 * 60, 16_000, 1, 16);
        let mut forged_rate = valid.clone();
        forged_rate[28..32].copy_from_slice(&u32::MAX.to_le_bytes());
        let mut wrong_align = valid.clone();
        wrong_align[32..34].copy_from_slice(&1_u16.to_le_bytes());
        let mut unknown_encoding = valid.clone();
        unknown_encoding[20..22].copy_from_slice(&6_u16.to_le_bytes());
        let mut duplicate_data = valid.clone();
        duplicate_data.extend_from_slice(b"data\x02\x00\x00\x00\x00\x00");
        let size = duplicate_data.len() as u32 - 8;
        duplicate_data[4..8].copy_from_slice(&size.to_le_bytes());
        let mut truncated = valid.clone();
        truncated.pop();
        for audio in [
            forged_rate,
            wrong_align,
            unknown_encoding,
            duplicate_data,
            truncated,
        ] {
            let encoded = base64::engine::general_purpose::STANDARD.encode(audio);
            assert!(parse_audio_payload(&encoded, "audio/wav").is_err());
        }
        let encoded = base64::engine::general_purpose::STANDARD.encode(valid);
        assert_eq!(parse_audio_payload(&encoded, "audio/wav").unwrap().1, 60);
    }

    #[test]
    fn windows_follow_utc_calendar_months_and_monday_weeks() {
        let windows = DictationWindows::at(1_793_020_799);
        assert_eq!(windows.month_start, 1_790_812_800);
        assert_eq!(windows.next_month_start, 1_793_491_200);
        assert_eq!(windows.week_start, 1_792_972_800);
        let december = DictationWindows::at(1_798_761_599);
        assert_eq!(december.next_month_start, 1_798_761_600);
        assert_eq!(
            DictationWindows::at(1_798_761_600).month_start,
            1_798_761_600
        );
        assert_eq!(
            DictationWindows::at(1_709_164_800).month_start,
            1_706_745_600
        );
    }

    #[test]
    fn definitions_are_limited_to_mai_transcription_options() {
        let speechkit = br#"{"enhancedMode":{"enabled":true,"model":"MAI-Transcribe-2","modelOptions":{"transcribeStyle":"clean"}},"phraseList":{"phrases":["tmux","kubectl"]},"locales":["sv"]}"#;
        let parsed = Definition::parse(speechkit).unwrap();
        assert_eq!(serde_json::to_vec(&parsed).unwrap(), speechkit.to_vec());
        for rejected in [
            &br#"{"enhancedMode":{"enabled":true,"model":"MAI-Transcribe-2"},"diarization":{"enabled":true}}"#[..],
            br#"{"enhancedMode":{"enabled":true,"model":"other"}}"#,
            br#"{"enhancedMode":{"enabled":true,"model":"MAI-Transcribe-2","task":"translate"}}"#,
            br#"{"enhancedMode":{"enabled":true,"model":"MAI-Transcribe-2","modelOptions":{"timestamps":"word"}}}"#,
            br#"{"enhancedMode":{"enabled":true,"model":"MAI-Transcribe-2"},"locales":["en","sv"]}"#,
            br#"{"enhancedMode":{"enabled":false,"model":"MAI-Transcribe-2"}}"#,
        ] {
            assert!(Definition::parse(rejected).is_err());
        }
        let too_many = serde_json::json!({"enhancedMode":{"enabled":true,"model":"MAI-Transcribe-2"},"phraseList":{"phrases":vec!["a"; 51]}});
        assert!(Definition::parse(&serde_json::to_vec(&too_many).unwrap()).is_err());
    }

    #[test]
    fn stream_headers_accept_only_open_or_exact_16k_mono_pcm() {
        let open = open_stream_wav_header();
        assert_eq!(
            parse_stream_wav_header(&open).unwrap(),
            StreamWavLength::Open
        );
        let exact = sample_wav(64_000, 16_000, 1, 16);
        assert_eq!(
            parse_stream_wav_header(&exact[..44]).unwrap(),
            StreamWavLength::Exact(64_000)
        );
        for wrong in [
            sample_wav(64_000, 48_000, 1, 16),
            sample_wav(64_000, 16_000, 2, 16),
            sample_wav(64_000, 16_000, 1, 8),
        ] {
            assert!(parse_stream_wav_header(&wrong[..44]).is_err());
        }
        let mut mixed = open.to_vec();
        mixed[40..44].copy_from_slice(&100_u32.to_le_bytes());
        assert!(parse_stream_wav_header(&mixed).is_err());
    }
}
