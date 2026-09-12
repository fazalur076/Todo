.PHONY: all app run test clean

all: app

app:
	@./Scripts/build_app.sh

test:
	@./Scripts/run_logic_tests.sh

run: app
	@open ProductivityApp.app

clean:
	@rm -rf .build ProductivityApp.app
	@echo "Cleaned build artifacts."
