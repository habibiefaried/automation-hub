#!/bin/bash
set -e

# Cleanup and Prep
rm -rf secrets
mkdir -p secrets

# 1. Generate Certificate Authority (CA)
echo "Generating CA..."
openssl req -new -x509 -keyout secrets/ca-key -out secrets/ca-cert -days 365 -nodes -subj "/CN=Kafka-Security-CA"

CRED="kafka123" # Password for JKS and Keys

generate_cert() {
  NAME=$1
  echo "Generating certs for $NAME..."
  
  # Create Keystore
  keytool -genkey -noprompt -alias $NAME -dname "CN=$NAME, OU=IT, O=Apache, L=City, C=US" \
    -keystore secrets/$NAME.keystore.jks -storepass $CRED -keypass $CRED -keyalg RSA
    
  # Create CSR & Sign it with CA
  keytool -keystore secrets/$NAME.keystore.jks -alias $NAME -certreq -file secrets/$NAME.csr -storepass $CRED
  openssl x509 -req -CA secrets/ca-cert -CAkey secrets/ca-key -in secrets/$NAME.csr -out secrets/$NAME-ca-signed.crt -days 365 -CAcreateserial -passin pass:$CRED
  
  # Import CA and Signed Cert into Keystore
  keytool -keystore secrets/$NAME.keystore.jks -alias CARoot -import -file secrets/ca-cert -noprompt -storepass $CRED
  keytool -keystore secrets/$NAME.keystore.jks -alias $NAME -import -file secrets/$NAME-ca-signed.crt -noprompt -storepass $CRED
  
  # Create Truststore (Public CA only)
  keytool -keystore secrets/$NAME.truststore.jks -alias CARoot -import -file secrets/ca-cert -noprompt -storepass $CRED
}

# Generate for 3 Controllers, 3 Brokers, and 1 Client
for i in 1 2 3; do generate_cert "controller-$i"; done
for i in 1 2 3; do generate_cert "broker-$i"; done
generate_cert "kafka-client"

# 2. Create JAAS Config File
# This tells the server how to validate SCRAM credentials
cat > secrets/kafka_server_jaas.conf <<EOF
KafkaServer {
    org.apache.kafka.common.security.scram.ScramLoginModule required
    username="admin"
    password="admin-secret";
};
EOF

chmod -R 777 secrets
echo "Certificates and JAAS config generated in ./secrets/"
