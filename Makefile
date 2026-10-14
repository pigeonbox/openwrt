.PHONY: build test vet frontend ipx clean

# PigeonBox OpenWrt/iStoreOS 适配层
# 独立构建钉 go.mod 正式版本(core v0.13.0);在 hub 工作区内直接跑会拾取
# 上层 go.work 联编本地 core,GOWORK=off 强制钉版构建,两者皆可。

build:            ## 编译本机二进制(dist/pigeonbox,默认 static-dir 指向包内路径)
	go build -o dist/pigeonbox ./cmd/pigeonbox

p2pc:             ## 下载随包 p2pc(版本=DEPS.env P2PC_REF;缺省跳过,直传优雅降级)
	@ref=$$(grep '^P2PC_REF=' DEPS.env 2>/dev/null | cut -d= -f2 | tr -d ' \r'); \
	[ -n "$$ref" ] || { echo "(DEPS.env 无 P2PC_REF,跳过 p2pc)"; exit 0; }; \
	arch=$$(uname -m); case "$$arch" in x86_64) triple=x86_64-unknown-linux-gnu;; aarch64|arm64) triple=aarch64-unknown-linux-gnu;; *) echo "unsupported: $$arch"; exit 1;; esac; \
	mkdir -p dist; \
	base="https://github.com/pigeonbox/p2p/releases/download/$$ref"; \
	tmp=$$(mktemp -d); \
	if curl -fsSL -m 60 -o "$$tmp/checksums.txt" "$$base/p2pc-checksums.txt" 2>/dev/null \
	   && curl -fsSL -m 300 -o "$$tmp/p2pc-$$triple" "$$base/p2pc-$$triple" 2>/dev/null; then :; \
	elif command -v gh >/dev/null 2>&1; then \
	  gh release download "$$ref" -R pigeonbox/p2p -p "p2pc-$$triple" -O "$$tmp/p2pc-$$triple" --clobber && \
	  gh release download "$$ref" -R pigeonbox/p2p -p p2pc-checksums.txt -O "$$tmp/checksums.txt" --clobber; \
	else echo "curl/gh 均失败"; rm -rf "$$tmp"; exit 1; fi; \
	(cd "$$tmp" && grep " p2pc-$$triple\$$" checksums.txt | shasum -a 256 -c - >/dev/null) || { echo "sha256 校验失败"; rm -rf "$$tmp"; exit 1; }; \
	install -m 0755 "$$tmp/p2pc-$$triple" dist/p2pc && rm -rf "$$tmp" && echo "✓ p2pc @ $$ref"

test:
	go test ./... -race

vet:
	go vet ./...

frontend:         ## 构建前端 dist(优先工作区 frontend 仓)→ dist/www
	./scripts/build-frontend.sh

ipk:              ## 组装本机架构冒烟 ipk(需先 build + frontend)
	./scripts/build-ipk.sh x86_64 0.0.0-dev

clean:
	rm -rf dist/ .frontend-src/
