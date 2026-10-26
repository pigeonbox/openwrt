.PHONY: build test vet frontend ipx p2pc clean

# PigeonBox OpenWrt/iStoreOS 适配层
# 独立构建钉 go.mod 正式版本(core 版本=DEPS.env CORE_PIN,勿在此硬编码:
# 硬编码的版本号必然过期,而过期版本号会**误导人**以为构建用的是那个版本);
# 在 hub 工作区内直接跑会拾取上层 go.work 联编本地 core ⇒ 构建一律
# GOWORK=off 强制钉版构建,两者皆可。
#
# 守卫:scripts/check-build-pin.sh 断言「产物里的 core 版本 == DEPS.env CORE_PIN」
# （GOWORK=off 时 go version -m 显示 vX.Y.Z;联编工作区时显示 (devel) ⇒ 变红）。

build:            ## 编译本机二进制(dist/pigeonbox,默认 static-dir 指向包内路径)
	GOWORK=off go build -o dist/pigeonbox ./cmd/pigeonbox

p2pc:             ## 下载随包 p2pc+p2pcweb(版本=DEPS.env P2PC_REF;缺省跳过,直传优雅降级)
	@triple=$$(case "$$(uname -m)" in x86_64) echo x86_64-unknown-linux-gnu;; aarch64|arm64) echo aarch64-unknown-linux-gnu;; *) echo unsupported: $$(uname -m); exit 1;; esac); \
	./scripts/fetch-p2pc.sh "$$triple" dist

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
