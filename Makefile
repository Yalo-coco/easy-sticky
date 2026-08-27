.PHONY: build test smoke app run

build:
	swift build --product EasySticky

test:
	swift run EasyStickyCoreChecks

smoke: app
	bash scripts/smoke-test.sh

app:
	bash scripts/build-app.sh

run:
	swift run EasySticky
