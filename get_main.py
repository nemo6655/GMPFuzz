import urllib.request

url = "https://raw.githubusercontent.com/cesanta/mongoose/7.20/tutorials/mqtt/mqtt-server/main.c"
with urllib.request.urlopen(url) as response:
    html = response.read().decode()
    print(html)
