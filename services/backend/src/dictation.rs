use anyhow::{Context, Result, bail, ensure};
use async_trait::async_trait;
use base64::Engine;
use reqwest::multipart::{Form, Part};
use reqwest::{Client, StatusCode};
use serde::Deserialize;
use thiserror::Error;

use crate::config::Settings;

const OPENAI_TRANSCRIPTION_MODEL: &str = "gpt-4o-mini-transcribe";

#[derive(Debug, Clone)]
pub struct DictationTranscriptionInput {
    pub audio_bytes: Vec<u8>,
    pub mime_type: String,
    pub file_name: String,
    pub instructions: Option<String>,
    pub language_hints: Vec<String>,
}

#[async_trait]
pub trait DictationTranscriber: Send + Sync {
    async fn transcribe(
        &self,
        request: DictationTranscriptionInput,
    ) -> std::result::Result<String, DictationTranscriberError>;
}

#[derive(Debug, Error)]
pub enum DictationTranscriberError {
    #[error("invalid audio payload")]
    InvalidAudioPayload,
    #[error("failed to prepare OpenAI transcription request")]
    InvalidRequest(#[source] anyhow::Error),
    #[error("failed to send OpenAI transcription request")]
    Request(#[source] reqwest::Error),
    #[error("OpenAI rejected the transcription request with status {status}: {detail}")]
    Rejected { status: StatusCode, detail: String },
}

#[derive(Clone)]
pub struct OpenAIDictationTranscriber {
    http_client: Client,
    transcriptions_url: String,
    api_key: String,
}

impl OpenAIDictationTranscriber {
    pub fn new(settings: &Settings) -> Result<Self> {
        let http_client = Client::builder()
            .connect_timeout(std::time::Duration::from_secs(10))
            .timeout(std::time::Duration::from_secs(120))
            .build()
            .context("failed to build OpenAI dictation client")?;

        Ok(Self {
            http_client,
            transcriptions_url: format!("{}/audio/transcriptions", settings.openai_base_url),
            api_key: settings.openai_api_key.clone(),
        })
    }
}

#[async_trait]
impl DictationTranscriber for OpenAIDictationTranscriber {
    async fn transcribe(
        &self,
        request: DictationTranscriptionInput,
    ) -> std::result::Result<String, DictationTranscriberError> {
        let file_part = Part::bytes(request.audio_bytes)
            .file_name(request.file_name)
            .mime_str(&request.mime_type)
            .map_err(|error| DictationTranscriberError::InvalidRequest(error.into()))?;

        let mut form = Form::new()
            .text("model", OPENAI_TRANSCRIPTION_MODEL.to_owned())
            .part("file", file_part);

        if let Some(instructions) = request.instructions
            && !instructions.is_empty()
        {
            form = form.text("prompt", instructions);
        }

        if request.language_hints.len() == 1 {
            form = form.text("language", request.language_hints[0].clone());
        }

        let response = self
            .http_client
            .post(&self.transcriptions_url)
            .bearer_auth(&self.api_key)
            .multipart(form)
            .send()
            .await
            .map_err(DictationTranscriberError::Request)?;

        let status = response.status();
        let mut response = response;
        let mut body_bytes = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(DictationTranscriberError::Request)?
        {
            if body_bytes.len() + chunk.len() > 128 * 1024 {
                return Err(DictationTranscriberError::InvalidRequest(anyhow::anyhow!(
                    "transcription response exceeds limit"
                )));
            }
            body_bytes.extend_from_slice(&chunk);
        }
        let body = String::from_utf8(body_bytes)
            .map_err(|error| DictationTranscriberError::InvalidRequest(error.into()))?;

        if !status.is_success() {
            return Err(DictationTranscriberError::Rejected {
                status,
                detail: truncate_error_body(&body, 400),
            });
        }

        let parsed_response = serde_json::from_str::<OpenAITranscriptionResponse>(&body)
            .map_err(|error| DictationTranscriberError::InvalidRequest(error.into()))?;

        Ok(parsed_response.text)
    }
}

#[derive(Clone)]
pub struct NoopDictationTranscriber;

#[async_trait]
impl DictationTranscriber for NoopDictationTranscriber {
    async fn transcribe(
        &self,
        _request: DictationTranscriptionInput,
    ) -> std::result::Result<String, DictationTranscriberError> {
        Err(DictationTranscriberError::InvalidAudioPayload)
    }
}

#[derive(Debug, Deserialize)]
struct OpenAITranscriptionResponse {
    text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DictationQuotaReservation {
    pub week_start_epoch_seconds: i64,
    pub quota_resets_at_epoch_seconds: i64,
    pub charged_seconds: i64,
    pub remaining_seconds_after_charge: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DictationQuotaExceeded {
    pub operator_limit: bool,
    pub remaining_seconds: i64,
    pub quota_resets_at_epoch_seconds: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DictationChargeWindow {
    pub week_start_epoch_seconds: i64,
    pub quota_resets_at_epoch_seconds: i64,
    pub charged_seconds: i64,
}

pub fn parse_audio_payload(
    audio_base64: &str,
    mime_type: &str,
) -> Result<(Vec<u8>, DictationChargeWindow)> {
    if mime_type != "audio/wav" {
        bail!("only audio/wav payloads are supported")
    }

    let audio_bytes = base64::engine::general_purpose::STANDARD
        .decode(audio_base64)
        .context("failed to decode base64 audio payload")?;

    let charged_seconds = parse_wav_duration_seconds(&audio_bytes)?;
    let now = current_epoch_seconds();
    let week_start_epoch_seconds = current_week_start_epoch_seconds(now);

    Ok((
        audio_bytes,
        DictationChargeWindow {
            week_start_epoch_seconds,
            quota_resets_at_epoch_seconds: week_start_epoch_seconds + 7 * 24 * 60 * 60,
            charged_seconds,
        },
    ))
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

fn current_week_start_epoch_seconds(now: i64) -> i64 {
    let seconds_per_day = 24 * 60 * 60;
    let days_since_epoch = now.div_euclid(seconds_per_day);
    let days_since_monday = (days_since_epoch + 3).rem_euclid(7);
    (days_since_epoch - days_since_monday) * seconds_per_day
}

fn truncate_error_body(body: &str, max_characters: usize) -> String {
    let single_line = body.replace('\n', " ");
    if single_line.chars().count() <= max_characters {
        return single_line;
    }
    format!(
        "{}…",
        single_line.chars().take(max_characters).collect::<String>()
    )
}

#[cfg(test)]
mod tests {
    use super::parse_audio_payload;
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

        let (_, charge_window) = parse_audio_payload(&encoded, "audio/wav").unwrap();

        assert_eq!(charge_window.charged_seconds, 2);
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
        assert_eq!(
            parse_audio_payload(&encoded, "audio/wav")
                .unwrap()
                .1
                .charged_seconds,
            60
        );
    }
}
