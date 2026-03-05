const net = require("net");
const app = require("./src/app");

// Azure App Service injects PORT — respect it strictly (no fallback needed there).
// Locally, try 3000 first, then scan upward until a free port is found.
function findFreePort(startPort) {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.unref();
    server.on("error", (err) => {
      if (err.code === "EADDRINUSE") {
        resolve(findFreePort(startPort + 1));
      } else {
        reject(err);
      }
    });
    server.listen(startPort, () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

async function start() {
  const preferredPort = parseInt(process.env.PORT || "3000", 10);
  const port = await findFreePort(preferredPort);

  if (!process.env.PORT && port !== preferredPort) {
    console.warn(`Port ${preferredPort} is in use — using port ${port} instead.`);
  }

  app.listen(port, () => {
    console.log(`Server running on http://localhost:${port}`);
  });
}

start();
