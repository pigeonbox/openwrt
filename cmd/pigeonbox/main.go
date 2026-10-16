// Package main 是 PigeonBox 的 OpenWrt/iStoreOS 原生包入口。
//
// 运行时形态:单进程单端口。本二进制以库调用方式拉起 PigeonBox 全部业务
// (bootstrap.BootstrapWithOptions),同端口经 SPA 回退服务前端静态资源,
// 由 procd(/etc/init.d/pigeonbox)托管,配置经 UCI→PB_* 环境变量注入。
//
// 与 server 仓部署壳的差异:JWT 密钥自动生成并持久化到数据目录——路由器用户
// 不应被迫手工生成密钥(core 安全基线在 production 模式缺强密钥时拒绝启动)。
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"flag"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/pigeonbox/core/bootstrap"
	"github.com/pigeonbox/core/pkg/logger"
	"github.com/oekit/core/version"
	"github.com/pigeonbox/openwrt/internal/adminsync"

	"go.uber.org/zap"
)

// ensureJWTSecret 保证 PB_JWT_SECRET 存在:未显式配置时自动生成强密钥,
// 持久化到数据目录(.jwt_secret,权限 0600),重启复用(已签发 token 不失效)。
// 与 fnos 适配层同款逻辑,两处需同步演进。
func ensureJWTSecret() {
	if os.Getenv("PB_JWT_SECRET") != "" {
		return
	}
	dataDir := os.Getenv("PB_DATA_PATH")
	if dataDir == "" {
		dataDir = "./data"
	}
	secretPath := filepath.Join(dataDir, ".jwt_secret")
	if b, err := os.ReadFile(secretPath); err == nil {
		if s := strings.TrimSpace(string(b)); len(s) >= 32 {
			_ = os.Setenv("PB_JWT_SECRET", s)
			return
		}
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		// 加密源不可用属系统级故障,直接失败
		_, _ = os.Stderr.WriteString("无法生成 JWT 密钥(crypto/rand 不可用): " + err.Error() + "\n")
		os.Exit(1)
	}
	secret := hex.EncodeToString(raw)
	_ = os.MkdirAll(dataDir, 0o755)
	if err := os.WriteFile(secretPath, []byte(secret), 0o600); err != nil {
		_, _ = os.Stderr.WriteString("无法持久化 JWT 密钥(" + secretPath + "): " + err.Error() + "\n")
		os.Exit(1)
	}
	_ = os.Setenv("PB_JWT_SECRET", secret)
}

func main() {
	// --config 指定 PigeonBox 配置文件路径(透传给 bootstrap)。
	// ipk 默认不携带配置文件;高级用户可创建 /etc/pigeonbox/config.yaml
	// (UCI→env 注入的变量优先级仍高于该文件)。
	configPath := flag.String("config", "", "配置文件路径(默认:存在 /etc/pigeonbox/config.yaml 时使用)")
	staticDir := flag.String("static-dir", "/usr/share/pigeonbox/www", "前端静态资源目录")
	flag.Parse()

	if *configPath == "" {
		if _, err := os.Stat("/etc/pigeonbox/config.yaml"); err == nil {
			*configPath = "/etc/pigeonbox/config.yaml"
		}
	}

	// 0. 保证 JWT 密钥存在(自动生成 + 数据目录持久化),必须在 bootstrap 读配置前注入。
	ensureJWTSecret()

	// 0.5 管理员密码同步:配置面(UCI admin_password)非空即权威——已有 admin
	//     时就地更新口令并吊销旧会话(见 internal/adminsync)。失败不阻断启动。
	dbPath := os.Getenv("PB_DATABASE_DB_NAME")
	if dbPath == "" {
		dataDir := os.Getenv("PB_DATA_PATH")
		if dataDir == "" {
			dataDir = "./data"
		}
		dbPath = filepath.Join(dataDir, "fileCodeBox.db")
	}
	if changed, err := adminsync.Sync(dbPath, os.Getenv("PB_ADMIN_PASSWORD")); err != nil {
		_, _ = os.Stderr.WriteString("管理员密码同步失败(不阻断启动): " + err.Error() + "\n")
	} else if changed {
		_, _ = os.Stderr.WriteString("已按 PB_ADMIN_PASSWORD 更新 admin 口令,旧会话已吊销\n")
	}

	// 1. 以库调用方式拉起 PigeonBox 全部业务,SPA 回退服务前端。
	//    返回的 *server.Hertz 已完成:读配置→初始化logger→建DB→建storage→装路由→装中间件。
	h, err := bootstrap.BootstrapWithOptions(*configPath, bootstrap.WithStaticDir(*staticDir))
	if err != nil {
		// 此时 logger 可能未初始化,fallback 到标准错误输出。
		_, _ = os.Stderr.WriteString("PigeonBox bootstrap 失败: " + err.Error() + "\n")
		os.Exit(1)
	}
	defer bootstrap.Cleanup()

	// 2. 启动 HTTP 服务。
	go func() {
		logger.Info("PigeonBox OpenWrt 服务启动中...",
			zap.String("version", version.Version),
			zap.String("commit", version.BuildCommit))
		h.Spin()
	}()

	// 3. 优雅退出:procd stop 发 SIGTERM,给在途请求 5s 排空窗口
	//    (procd 默认 term_timeout 5s 后 SIGKILL,窗口对齐)。
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	logger.Info("正在关闭服务...")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := h.Shutdown(shutdownCtx); err != nil {
		logger.Warn("优雅关闭超时,存在未完成的在途请求", zap.Error(err))
	}
	logger.Info("服务已停止")
}
