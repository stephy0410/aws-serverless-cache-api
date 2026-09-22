PROFILE ?= academy
URL     ?= $(shell terraform output -raw api_url 2>/dev/null)

.PHONY: build deploy destroy wrk2 loadtest smoke

## Install Lambda dependencies (pure JS, so a macOS install runs fine on Lambda) and fetch the RDS CA bundle.
build:
	cd app && npm install --omit=dev --no-audit --no-fund
	curl -sSfo app/rds-ca.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem

deploy: build
	terraform init -input=false
	terraform apply

destroy:
	terraform destroy

wrk2:
	loadtest/build-wrk2.sh

smoke:
	@for p in /health /products/42 /products/42 "/products/top?category=books" /stats; do \
	  echo "GET $$p"; curl -sk -D - "$(URL)$$p" -o /tmp/cache-api-body | grep -iE '^(HTTP|x-cache)'; cat /tmp/cache-api-body; echo; echo; \
	done

loadtest: wrk2
	loadtest/run.sh $(URL)
