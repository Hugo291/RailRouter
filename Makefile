# TchouTchou — build / test / run / install
.PHONY: build app run test install clean

build:        ## Compile (swift build)
	swift build

app: build    ## Assemble le bundle .app signé (build/TchouTchou.app)
	./build-app.sh

run: app      ## Build + lancement
	open build/TchouTchou.app

test:         ## Tests unitaires (normalisation, conflits, parsing API)
	swift run TchouTchou --run-tests

install: app  ## Copie dans /Applications
	rm -rf /Applications/TchouTchou.app
	cp -R build/TchouTchou.app /Applications/
	@echo "✅ Installé : /Applications/TchouTchou.app"

clean:
	rm -rf .build build
