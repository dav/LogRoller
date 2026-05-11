INSTALL_DIR ?= ~/bin
SKILL_DIR = ~/.claude/skills/logroller-client-integration
VERSION_FILE = version.txt
DEPLOY_HOST = 23.92.26.189
DEPLOY_PATH = akuaku.org/LogRoller/
DMG_BUILD_DIR = /tmp/LogRollerBuild
DMG_PATH = $(DMG_BUILD_DIR)/LogRoller.dmg

.PHONY: cli cli-debug install uninstall clean deploy deploy-html-only bump-build dmg

# Build CLI tool (release)
cli:
	xcodegen generate
	xcodebuild \
		-project LogRoller.xcodeproj \
		-scheme logroller \
		-configuration Release \
		-destination 'platform=macOS' \
		-derivedDataPath /tmp/LogRollerDerivedData \
		build 2>&1 | tee /tmp/xcodebuild.log | tail -3

# Build CLI tool (debug, faster compile)
cli-debug:
	xcodegen generate
	xcodebuild \
		-project LogRoller.xcodeproj \
		-scheme logroller \
		-configuration Debug \
		-destination 'platform=macOS' \
		build 2>&1 | tee /tmp/xcodebuild.log | tail -3

# Build app + CLI, install to /Applications and ~/bin, install skill
install: cli
	@echo "→ Building app..."
	xcodebuild \
		-project LogRoller.xcodeproj \
		-scheme LogRollerApp \
		-configuration Release \
		-destination 'platform=macOS' \
		-derivedDataPath /tmp/LogRollerDerivedData \
		build 2>&1 | tee /tmp/xcodebuild.log | tail -3
	@echo "→ Installing LogRoller.app to /Applications..."
	@pkill -x LogRoller 2>/dev/null || true
	@sleep 1
	@rm -rf /Applications/LogRoller.app
	@cp -R /tmp/LogRollerDerivedData/Build/Products/Release/LogRoller.app /Applications/
	@echo "✓ LogRoller.app installed"
	@mkdir -p $(INSTALL_DIR)
	@rm -f $(INSTALL_DIR)/logroller
	@cp /tmp/LogRollerDerivedData/Build/Products/Release/logroller $(INSTALL_DIR)/logroller
	@mkdir -p $(SKILL_DIR)
	@cp skills/logroller-client-integration/SKILL.md $(SKILL_DIR)/SKILL.md
	@echo "✓ logroller CLI installed to $(INSTALL_DIR)"
	@echo "✓ Claude Code skill installed to $(SKILL_DIR)"

# Remove symlinks
uninstall:
	rm -f $(INSTALL_DIR)/logroller
	@echo "Removed logroller from $(INSTALL_DIR)"

# Clean build artifacts
clean:
	rm -rf /tmp/LogRollerDerivedData /tmp/LogRollerBuild
	@echo "Cleaned build artifacts"

# Bump build number in version.txt and project.yml
bump-build:
	@VERSION=$$(sed -n '1p' $(VERSION_FILE)); \
	BUILD=$$(sed -n '2p' $(VERSION_FILE)); \
	NEW_BUILD=$$((BUILD + 1)); \
	printf '%s\n%s\n' "$$VERSION" "$$NEW_BUILD" > $(VERSION_FILE); \
	sed -i '' "s/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: $$NEW_BUILD/" project.yml; \
	echo "Bumped build number: $$BUILD → $$NEW_BUILD (version $$VERSION)"

# Build the signed, notarized DMG
dmg: bump-build
	@echo "=== Building DMG ==="
	Scripts/build-release.sh

# Full deploy: bump build, create DMG, zip, deploy to server
deploy: dmg
	@VERSION=$$(sed -n '1p' $(VERSION_FILE)); \
	BUILD=$$(sed -n '2p' $(VERSION_FILE)); \
	echo ""; \
	echo "=== Distributing v$$VERSION ($$BUILD) ==="; \
	echo ""; \
	echo "→ Creating zip..."; \
	mkdir -p html; \
	zip -j html/LogRoller.dmg.zip "$(DMG_PATH)"; \
	echo "✓ LogRoller.dmg.zip created in html/"; \
	echo ""; \
	echo "→ Deploying to $(DEPLOY_HOST)..."; \
	scp html/* $(DEPLOY_HOST):$(DEPLOY_PATH); \
	echo "✓ Deployed to $(DEPLOY_HOST):$(DEPLOY_PATH)"; \
	echo ""; \
	echo "=== Deploy complete: v$$VERSION ($$BUILD) ==="

# Deploy only html/ (no DMG build)
deploy-html-only:
	@echo "→ Deploying html/ to $(DEPLOY_HOST)..."
	scp html/* $(DEPLOY_HOST):$(DEPLOY_PATH)
	@echo "✓ Deployed to $(DEPLOY_HOST):$(DEPLOY_PATH)"
