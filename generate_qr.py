import qrcode

url = "http://13.60.58.151:8000/clock/"

img = qrcode.make(url)

img.save("restaurant_clock_qr.png")

print("QR code created")
