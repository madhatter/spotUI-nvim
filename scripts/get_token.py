import http.server, urllib.parse, webbrowser, requests, base64, json, os
from dotenv import load_dotenv

load_dotenv()

CLIENT_ID = os.environ.get("SPOTIFY_CLIENT_ID") 
CLIENT_SECRET = os.environ.get("SPOTIFY_CLIENT_SECRET")
REDIRECT_URI = "http://127.0.0.1:8888/callback"

auth_url = (
    "https://accounts.spotify.com/authorize"
    f"?client_id={CLIENT_ID}&response_type=code"
    f"&redirect_uri={urllib.parse.quote(REDIRECT_URI)}"
    "&scope=user-read-currently-playing%20user-read-playback-state"
)
webbrowser.open(auth_url)

# Tiny local server catches the redirect from Spotify
code = None
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        global code
        code = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)['code'][0]
        self.send_response(200); self.end_headers()
        self.wfile.write(b"Done! Close this tab.")
    def log_message(self, *_): pass

http.server.HTTPServer(('localhost', 8888), Handler).handle_request()

# Exchange the code for access + refresh tokens
creds = base64.b64encode(f"{CLIENT_ID}:{CLIENT_SECRET}".encode()).decode()
resp = requests.post("https://accounts.spotify.com/api/token",
    headers={"Authorization": f"Basic {creds}"},
    data={"grant_type": "authorization_code", "code": code, "redirect_uri": REDIRECT_URI}
).json()

json.dump({
    "access_token": resp["access_token"],
    "refresh_token": resp["refresh_token"],
    "client_id": CLIENT_ID,
    "client_secret": CLIENT_SECRET,
}, open(os.path.expanduser("~/.spotify_nvim_tokens.json"), "w"), indent=2)

print("Saved to ~/.spotify_nvim_tokens.json")
