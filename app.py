import logging
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

REQUIRED_ENV = "REQUIRED_TOKEN"

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != '/health':
            self.send_response(404)
            self.send_header("Content-type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"Not Found\n")
            logging.info("GET %s - 404 Not Found", self.path)
            return
        
        required_value = os.getenv(REQUIRED_ENV)
        if required_value is None or required_value == "":
            self.send_response(500)
            self.send_header("Content-type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write(b"unhealthy: missing REQUIRED_TOKEN\n")
            logging.error("GET /health -> 500 (missing %s)", REQUIRED_ENV)
            return
        
        self.send_response(200)
        self.send_header("Content-type", "text/plain; charset=utf-8")   
        self.end_headers()
        self.wfile.write(b"healthy\n")
        logging.info("GET /health -> 200")

        def log_message(self, format, *args):
            return
        
def main():
    port = int(os.getenv("PORT", "8080"))
    addr = ("0.0.0.0", port)
    logging.info("Starting server on %s:%s", addr[0], addr[1])
    logging.info("%s is %s", REQUIRED_ENV, "present" if os.getenv(REQUIRED_ENV) else "missing")
    
    server = HTTPServer(addr, Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logging.info("Shutdown requested (Ctrl + C)")
        server.server_close()
    finally:
        server.shutdown()
        server.server_close()
        logging.info("Server stopped")




if __name__ == "__main__":
    main()