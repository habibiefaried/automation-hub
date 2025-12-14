## Description

it is above `apache-kafka-yaml` but with TLS and SASL SCRAM auth option

## Execution order

```
chmod +x generate-kafka-tls.sh
./generate-kafka-tls.sh
# confirm secrets exist:
kubectl -n kafka-secure get secret kafka-tls-secret kafka-superadmin-secret
```

```
kubectl apply -f .
kubectl -n kafka-secure get pods -w
```

```
# get one broker pod name
kubectl -n kafka-secure get pods -l app=broker-1
# or exec to deployment:
kubectl -n kafka-secure exec -it deploy/broker-1 -- bash

<INSIDE POD RUN>

# use internal PLAINTEXT port 19092 to avoid SASL chicken-egg
POD# bin/kafka-configs.sh \
  --bootstrap-server localhost:19092 \
  --alter --add-config 'SCRAM-SHA-256=[iterations=4096,password=superpassword123]' \
  --entity-type users --entity-name superadmin

# verify
POD# bin/kafka-configs.sh --bootstrap-server localhost:19092 --describe --entity-type users --entity-name superadmin
```

## cleanup

```
kubectl delete all --all -n kafka-secure
```
