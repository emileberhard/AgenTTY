use anyhow::{Context, Result, ensure};
use base64::{
    Engine,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use jsonwebtoken::{Algorithm, DecodingKey, Validation, decode, decode_header};
use openssl::{
    stack::Stack,
    x509::{
        X509, X509StoreContext,
        store::X509StoreBuilder,
        verify::{X509VerifyFlags, X509VerifyParam},
    },
};
use serde::{Deserialize, de::DeserializeOwned};
use x509_parser::prelude::{FromDer, X509Certificate};

use crate::{models::MAIN_BUNDLE_ID, storage::hash_text};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AppTransaction {
    app_transaction_id: String,
    bundle_id: String,
    app_apple_id: Option<u64>,
    receipt_type: String,
    receipt_creation_date: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Transaction {
    original_transaction_id: String,
    bundle_id: String,
    product_id: String,
    #[serde(rename = "type")]
    kind: String,
    environment: String,
    signed_date: i64,
    revocation_date: Option<i64>,
    app_transaction_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedAppTransaction {
    pub identity: String,
    environment: String,
    app_transaction_id: String,
}

pub fn verify(signed: &str, app_apple_id: u64) -> Result<VerifiedAppTransaction> {
    verify_app_transaction(signed, app_apple_id, apple_root()?)
}

pub fn verify_lifetime_purchase(
    signed: &str,
    app: &VerifiedAppTransaction,
    product_id: &str,
) -> Result<String> {
    verify_lifetime_purchase_with_root(signed, app, product_id, apple_root()?)
}

fn apple_root() -> Result<X509> {
    Ok(X509::from_der(include_bytes!(
        "../resources/AppleRootCA-G3.cer"
    ))?)
}

fn verify_app_transaction(
    signed: &str,
    app_apple_id: u64,
    root: X509,
) -> Result<VerifiedAppTransaction> {
    let transaction: AppTransaction =
        verify_apple_signed(signed, root, |payload: &AppTransaction| {
            payload.receipt_creation_date
        })?;
    ensure!(
        transaction.bundle_id == MAIN_BUNDLE_ID,
        "incorrect app bundle"
    );
    ensure!(
        matches!(transaction.receipt_type.as_str(), "Production" | "Sandbox"),
        "unsupported store environment"
    );
    ensure!(
        transaction
            .app_apple_id
            .map_or(transaction.receipt_type == "Sandbox", |id| id
                == app_apple_id),
        "incorrect App Store app ID"
    );
    ensure!(
        !transaction.app_transaction_id.is_empty() && transaction.app_transaction_id.len() <= 256,
        "invalid app transaction ID"
    );
    Ok(VerifiedAppTransaction {
        identity: hash_text(&format!(
            "{}:{}",
            transaction.receipt_type, transaction.app_transaction_id
        )),
        environment: transaction.receipt_type,
        app_transaction_id: transaction.app_transaction_id,
    })
}

fn verify_lifetime_purchase_with_root(
    signed: &str,
    app: &VerifiedAppTransaction,
    product_id: &str,
    root: X509,
) -> Result<String> {
    let transaction: Transaction =
        verify_apple_signed(signed, root, |payload: &Transaction| payload.signed_date)?;
    ensure!(
        transaction.bundle_id == MAIN_BUNDLE_ID
            && transaction.product_id == product_id
            && transaction.kind == "Non-Consumable",
        "not the lifetime purchase"
    );
    ensure!(
        transaction.environment == "Production" && app.environment == "Production",
        "only App Store purchases grant the lifetime tier"
    );
    ensure!(
        transaction.revocation_date.is_none(),
        "lifetime purchase was revoked"
    );
    ensure!(
        transaction
            .app_transaction_id
            .as_ref()
            .is_none_or(|id| *id == app.app_transaction_id),
        "purchase belongs to another app transaction"
    );
    ensure!(
        !transaction.original_transaction_id.is_empty()
            && transaction.original_transaction_id.len() <= 64,
        "invalid original transaction ID"
    );
    Ok(hash_text(&format!(
        "purchase:{}:{}",
        transaction.environment, transaction.original_transaction_id
    )))
}

fn verify_apple_signed<T: DeserializeOwned>(
    signed: &str,
    root: X509,
    signed_at_milliseconds: impl Fn(&T) -> i64,
) -> Result<T> {
    ensure!(signed.len() <= 24 * 1024, "signed payload exceeds limit");
    let header = decode_header(signed)?;
    ensure!(
        header.alg == Algorithm::ES256,
        "unexpected signing algorithm"
    );
    let certificates = header.x5c.context("missing signing certificates")?;
    ensure!(certificates.len() == 3, "invalid certificate chain length");
    let leaf_der = STANDARD.decode(&certificates[0])?;
    let intermediate_der = STANDARD.decode(&certificates[1])?;
    for (der, oid) in [
        (&leaf_der, "1.2.840.113635.100.6.11.1"),
        (&intermediate_der, "1.2.840.113635.100.6.2.1"),
    ] {
        let (remaining, certificate) = X509Certificate::from_der(der)
            .map_err(|_| anyhow::anyhow!("invalid signing certificate"))?;
        ensure!(remaining.is_empty(), "trailing certificate data");
        ensure!(
            certificate
                .extensions()
                .iter()
                .filter(|extension| extension.oid.to_id_string() == oid)
                .count()
                == 1,
            "missing Apple signing extension"
        );
    }
    let leaf = X509::from_der(&leaf_der)?;
    let intermediate = X509::from_der(&intermediate_der)?;
    let payload = signed.split('.').nth(1).context("missing signed payload")?;
    let unverified: T = serde_json::from_slice(&URL_SAFE_NO_PAD.decode(payload)?)?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_secs() as i64;
    let signed_at = signed_at_milliseconds(&unverified) / 1000;
    ensure!(
        signed_at > 0 && signed_at <= now + 60,
        "invalid signing time"
    );
    let mut store = X509StoreBuilder::new()?;
    store.add_cert(root)?;
    store.set_flags(X509VerifyFlags::X509_STRICT)?;
    let mut parameters = X509VerifyParam::new()?;
    parameters.set_time(signed_at);
    store.set_param(&parameters)?;
    let mut chain = Stack::new()?;
    chain.push(intermediate)?;
    let valid = X509StoreContext::new()?.init(&store.build(), &leaf, &chain, |context| {
        context.verify_cert()
    })?;
    ensure!(valid, "untrusted App Store certificate chain");
    let mut validation = Validation::new(Algorithm::ES256);
    validation.required_spec_claims.clear();
    validation.validate_exp = false;
    validation.validate_aud = false;
    let key = DecodingKey::from_ec_pem(&leaf.public_key()?.public_key_to_pem()?)?;
    Ok(decode::<T>(signed, &key, &validation)?.claims)
}

#[cfg(test)]
mod tests {
    use super::*;
    use openssl::{
        asn1::{Asn1Integer, Asn1Time},
        bn::BigNum,
        ec::{EcGroup, EcKey},
        hash::MessageDigest,
        nid::Nid,
        pkey::{PKey, Private},
        x509::{
            X509Extension, X509NameBuilder,
            extension::{AuthorityKeyIdentifier, BasicConstraints, KeyUsage, SubjectKeyIdentifier},
        },
    };

    fn certificate(
        issuer: Option<(&X509, &PKey<Private>)>,
        ca: bool,
        oid: Option<&str>,
        serial: u32,
    ) -> (X509, PKey<Private>) {
        let group = EcGroup::from_curve_name(Nid::X9_62_PRIME256V1).unwrap();
        let key = PKey::from_ec_key(EcKey::generate(&group).unwrap()).unwrap();
        let mut name = X509NameBuilder::new().unwrap();
        name.append_entry_by_text("CN", &format!("Test {serial}"))
            .unwrap();
        let name = name.build();
        let mut builder = X509::builder().unwrap();
        builder.set_version(2).unwrap();
        builder
            .set_serial_number(&Asn1Integer::from_bn(&BigNum::from_u32(serial).unwrap()).unwrap())
            .unwrap();
        builder.set_subject_name(&name).unwrap();
        builder
            .set_issuer_name(issuer.map_or(&*name, |(cert, _)| cert.subject_name()))
            .unwrap();
        builder.set_pubkey(&key).unwrap();
        builder
            .set_not_before(&Asn1Time::days_from_now(0).unwrap())
            .unwrap();
        builder
            .set_not_after(&Asn1Time::days_from_now(30).unwrap())
            .unwrap();
        let mut constraints = BasicConstraints::new();
        constraints.critical();
        if ca {
            constraints.ca();
        }
        builder
            .append_extension(constraints.build().unwrap())
            .unwrap();
        let mut usage = KeyUsage::new();
        usage.critical();
        if ca {
            usage.key_cert_sign().crl_sign();
        } else {
            usage.digital_signature();
        }
        builder.append_extension(usage.build().unwrap()).unwrap();
        let ski = SubjectKeyIdentifier::new()
            .build(&builder.x509v3_context(issuer.map(|(cert, _)| cert.as_ref()), None))
            .unwrap();
        builder.append_extension(ski).unwrap();
        if let Some((cert, _)) = issuer {
            let aki = AuthorityKeyIdentifier::new()
                .keyid(true)
                .build(&builder.x509v3_context(Some(cert), None))
                .unwrap();
            builder.append_extension(aki).unwrap();
        }
        if let Some(oid) = oid {
            let extension = X509Extension::new_from_der(
                &openssl::asn1::Asn1Object::from_str(oid).unwrap(),
                false,
                &openssl::asn1::Asn1OctetString::new_from_bytes(&[0x05, 0]).unwrap(),
            )
            .unwrap();
            builder.append_extension(extension).unwrap();
        }
        builder
            .sign(issuer.map_or(&key, |(_, key)| key), MessageDigest::sha256())
            .unwrap();
        (builder.build(), key)
    }

    #[test]
    fn admits_only_signed_app_store_identity_for_this_app() {
        let (root, root_key) = certificate(None, true, None, 1);
        let (intermediate, intermediate_key) = certificate(
            Some((&root, &root_key)),
            true,
            Some("1.2.840.113635.100.6.2.1"),
            2,
        );
        let (leaf, leaf_key) = certificate(
            Some((&intermediate, &intermediate_key)),
            false,
            Some("1.2.840.113635.100.6.11.1"),
            3,
        );
        let mut header = jsonwebtoken::Header::new(Algorithm::ES256);
        header.x5c = Some(vec![
            STANDARD.encode(leaf.to_der().unwrap()),
            STANDARD.encode(intermediate.to_der().unwrap()),
            STANDARD.encode(root.to_der().unwrap()),
        ]);
        let key =
            jsonwebtoken::EncodingKey::from_ec_pem(&leaf_key.private_key_to_pem_pkcs8().unwrap())
                .unwrap();
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as i64;
        let payload = serde_json::json!({"appTransactionId":"account-1", "bundleId":MAIN_BUNDLE_ID, "appAppleId":42, "receiptType":"Production", "receiptCreationDate":now});
        let sign =
            |payload: &serde_json::Value| jsonwebtoken::encode(&header, payload, &key).unwrap();
        let valid = sign(&payload);
        let identity = verify_app_transaction(&valid, 42, root.clone()).unwrap();
        assert_eq!(identity.identity, hash_text("Production:account-1"));
        assert!(verify_app_transaction(&valid, 43, root.clone()).is_err());
        let mut other_bundle = payload.clone();
        other_bundle["bundleId"] = serde_json::json!("other.app");
        assert!(verify_app_transaction(&sign(&other_bundle), 42, root.clone()).is_err());
        let mut sandbox = payload.clone();
        sandbox["receiptType"] = serde_json::json!("Sandbox");
        sandbox.as_object_mut().unwrap().remove("appAppleId");
        assert!(verify_app_transaction(&sign(&sandbox), 42, root.clone()).is_ok());
        let mut unsigned_environment = payload.clone();
        unsigned_environment["receiptType"] = serde_json::json!("Xcode");
        assert!(verify_app_transaction(&sign(&unsigned_environment), 42, root.clone()).is_err());
        let mut segments: Vec<String> = valid.split('.').map(str::to_owned).collect();
        segments[1] = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&other_bundle).unwrap());
        assert!(verify_app_transaction(&segments.join("."), 42, root.clone()).is_err());
        let (untrusted_root, _) = certificate(None, true, None, 10);
        assert!(verify_app_transaction(&valid, 42, untrusted_root).is_err());
        assert!(verify(&valid, 42).is_err());
    }

    #[test]
    fn lifetime_tier_requires_this_apps_unrevoked_purchase() {
        let (root, root_key) = certificate(None, true, None, 1);
        let (intermediate, intermediate_key) = certificate(
            Some((&root, &root_key)),
            true,
            Some("1.2.840.113635.100.6.2.1"),
            2,
        );
        let (leaf, leaf_key) = certificate(
            Some((&intermediate, &intermediate_key)),
            false,
            Some("1.2.840.113635.100.6.11.1"),
            3,
        );
        let mut header = jsonwebtoken::Header::new(Algorithm::ES256);
        header.x5c = Some(vec![
            STANDARD.encode(leaf.to_der().unwrap()),
            STANDARD.encode(intermediate.to_der().unwrap()),
            STANDARD.encode(root.to_der().unwrap()),
        ]);
        let key =
            jsonwebtoken::EncodingKey::from_ec_pem(&leaf_key.private_key_to_pem_pkcs8().unwrap())
                .unwrap();
        let sign =
            |payload: &serde_json::Value| jsonwebtoken::encode(&header, payload, &key).unwrap();
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as i64;
        let app = verify_app_transaction(
            &sign(&serde_json::json!({"appTransactionId":"account-1", "bundleId":MAIN_BUNDLE_ID, "appAppleId":42, "receiptType":"Production", "receiptCreationDate":now})),
            42,
            root.clone(),
        )
        .unwrap();
        let purchase = serde_json::json!({"originalTransactionId":"1000", "bundleId":MAIN_BUNDLE_ID, "productId":"lifetime", "type":"Non-Consumable", "environment":"Production", "signedDate":now, "appTransactionId":"account-1"});
        let verify = |payload: &serde_json::Value| {
            verify_lifetime_purchase_with_root(&sign(payload), &app, "lifetime", root.clone())
        };
        assert_eq!(
            verify(&purchase).unwrap(),
            hash_text("purchase:Production:1000")
        );
        let mut without_binding = purchase.clone();
        without_binding
            .as_object_mut()
            .unwrap()
            .remove("appTransactionId");
        assert!(verify(&without_binding).is_ok());
        for (field, value) in [
            ("productId", serde_json::json!("other")),
            ("type", serde_json::json!("Consumable")),
            ("environment", serde_json::json!("Sandbox")),
            ("revocationDate", serde_json::json!(now)),
            ("appTransactionId", serde_json::json!("account-2")),
            ("bundleId", serde_json::json!("other.app")),
        ] {
            let mut forged = purchase.clone();
            forged[field] = value;
            assert!(verify(&forged).is_err(), "{field} must be rejected");
        }
        let sandbox_app = verify_app_transaction(
            &sign(&serde_json::json!({"appTransactionId":"account-1", "bundleId":MAIN_BUNDLE_ID, "receiptType":"Sandbox", "receiptCreationDate":now})),
            42,
            root.clone(),
        )
        .unwrap();
        let mut sandbox_purchase = purchase.clone();
        sandbox_purchase["environment"] = serde_json::json!("Sandbox");
        assert!(
            verify_lifetime_purchase_with_root(
                &sign(&sandbox_purchase),
                &sandbox_app,
                "lifetime",
                root.clone()
            )
            .is_err(),
            "free sandbox purchases must not grant the lifetime tier"
        );
        let (untrusted_root, _) = certificate(None, true, None, 10);
        assert!(
            verify_lifetime_purchase_with_root(&sign(&purchase), &app, "lifetime", untrusted_root)
                .is_err()
        );
    }
}
