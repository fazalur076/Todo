.PHONY: all app run test clean

all: app

app:
	@./Scripts/build_app.sh

test:
	@./Scripts/run_logic_tests.sh

run: app
	@open Todo.app

clean:
	@rm -rf .build Todo.app ProductivityApp.app Cadence.app
	@echo "Cleaned build artifacts."
