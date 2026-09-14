.PHONY: all app run test install installer clean

all: app

app:
	@./Scripts/build_app.sh

installer:
	@./Scripts/build_installer.sh

install:
	@./Scripts/install.sh --cli

test:
	@./Scripts/run_logic_tests.sh

run: app
	@open Todo.app

clean:
	@rm -rf .build Todo.app ProductivityApp.app Cadence.app
	@echo "Cleaned build artifacts."
