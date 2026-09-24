"""Generate disposable TLS fixtures. Never install this CA in a system store."""
import datetime as dt
from pathlib import Path
import sys

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID

out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
now = dt.datetime.now(dt.timezone.utc)


def issue(name, issuer=None, ca=False, expired=False, dns=None):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, name)])
    parent_cert, parent_key = issuer if issuer else (None, key)
    builder = (x509.CertificateBuilder().subject_name(subject)
               .issuer_name(parent_cert.subject if parent_cert else subject)
               .public_key(key.public_key()).serial_number(x509.random_serial_number())
               .not_valid_before(now - dt.timedelta(days=3))
               .not_valid_after(now + dt.timedelta(days=-1 if expired else 3))
               .add_extension(x509.BasicConstraints(ca=ca, path_length=None), True)
               .add_extension(x509.KeyUsage(digital_signature=True,
                    content_commitment=False, key_encipherment=not ca,
                    data_encipherment=False, key_agreement=False,
                    key_cert_sign=ca, crl_sign=ca, encipher_only=False,
                    decipher_only=False), True)
               .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), False))
    if not ca:
        builder = builder.add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), False)
        builder = builder.add_extension(x509.SubjectAlternativeName([
            x509.DNSName(item) for item in (dns or ['proxy.fixture.invalid', 'nonce.fixture.invalid'])]), False)
    cert = builder.sign(parent_key, hashes.SHA256())
    (out / f'{name}.pem').write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    (out / f'{name}.key').write_bytes(key.private_bytes(serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    return cert, key


root = issue('root', ca=True)
unknown = issue('unknown-root', ca=True)
intermediate = issue('intermediate', root, ca=True)
issue('valid', root)
issue('wrong-name', root, dns=['wrong.fixture.invalid'])
issue('expired', root, expired=True)
issue('unknown', unknown)
issue('chain', intermediate)
(out / 'full-chain.pem').write_bytes((out / 'chain.pem').read_bytes() + (out / 'intermediate.pem').read_bytes())
(out / 'empty.pem').write_bytes(b'')
(out / 'empty-dir').mkdir(exist_ok=True)
print('FIXTURE_CERTIFICATES_CREATED')
