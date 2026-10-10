# RailRouter — build / test / run / install
.PHONY: build app run test install clean

build:        ## Compile (swift build)
	swift build

app: build    ## Assemble le bundle .app signé (build/RailRouter.app)
	./build-app.sh

run: app      ## Build + lancement
	open build/RailRouter.app

test:         ## Tests unitaires (normalisation, conflits, parsing API)
	swift run RailRouter --run-tests

install: app  ## Copie dans /Applications
	rm -rf /Applications/RailRouter.app
	cp -R build/RailRouter.app /Applications/
	@echo "✅ Installé : /Applications/RailRouter.app"

clean:
	rm -rf .build build
