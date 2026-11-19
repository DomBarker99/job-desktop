#!/usr/bin/env python3
"""Runs inside the container. Connects to the VNC screen the way a viewer does,
checks that it asks for NO password, takes a picture of the screen, and checks
that the picture is a drawn desktop and not a blank rectangle.

Writes the picture to /tmp/desktop-screen.png. Needs nothing but Python itself.
"""
import socket
import struct
import time
import zlib


def receive(sock, length):
    result = bytearray()
    while len(result) < length:
        part = sock.recv(length - len(result))
        if not part:
            raise RuntimeError('The VNC connection closed early')
        result.extend(part)
    return bytes(result)


def write_png(path, width, height, rgb):
    def chunk(kind, data):
        body = kind + data
        return struct.pack('>I', len(data)) + body + struct.pack('>I', zlib.crc32(body))
    stride = width * 3
    rows = b''.join(b'\x00' + rgb[y * stride:(y + 1) * stride] for y in range(height))
    with open(path, 'wb') as out:
        out.write(b'\x89PNG\r\n\x1a\n')
        out.write(chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)))
        out.write(chunk(b'IDAT', zlib.compress(rows, 6)))
        out.write(chunk(b'IEND', b''))


with socket.create_connection(('127.0.0.1', 5901), timeout=20) as sock:
    version = receive(sock, 12)
    assert version.startswith(b'RFB 003.'), version
    sock.sendall(b'RFB 003.008\n')
    count = receive(sock, 1)[0]
    assert count, 'The VNC server offered no way in at all'
    types = receive(sock, count)
    # 1 is "None" (no password), 2 is the classic VNC password.
    assert 1 in types, f'The VNC server wants a password (offered {list(types)})'
    sock.sendall(b'\x01')
    assert struct.unpack('>I', receive(sock, 4))[0] == 0, 'The VNC server refused the connection'
    sock.sendall(b'\x01')  # Share the screen with other viewers.
    width, height = struct.unpack('>HH', receive(sock, 4))
    receive(sock, 16)  # The server's own pixel format; a known one is asked for below.
    receive(sock, struct.unpack('>I', receive(sock, 4))[0])  # The desktop's name.
    # Press Escape: the GNOME desktop starts in its overview, and this leaves it,
    # so open windows show in the picture. It also proves the keyboard gets through.
    for down in (1, 0):
        sock.sendall(struct.pack('>BBHI', 4, down, 0, 0xFF1B))
    time.sleep(2)
    # Ask for 32-bit pixels (blue, green, red, unused), uncompressed, whole screen.
    sock.sendall(struct.pack('>BxxxBBBBHHHBBBxxx', 0, 32, 24, 0, 1, 255, 255, 255, 16, 8, 0))
    sock.sendall(struct.pack('>BBHi', 2, 0, 1, 0))
    sock.sendall(struct.pack('>BBHHHH', 3, 0, 0, 0, width, height))
    screen = bytearray(width * height * 4)
    while True:
        message = receive(sock, 1)[0]
        if message == 0:  # A picture update.
            receive(sock, 1)
            for _ in range(struct.unpack('>H', receive(sock, 2))[0]):
                x, y, w, h, encoding = struct.unpack('>HHHHi', receive(sock, 12))
                assert encoding == 0, f'Unexpected picture encoding {encoding}'
                pixels = receive(sock, w * h * 4)
                for row in range(h):
                    start = ((y + row) * width + x) * 4
                    screen[start:start + w * 4] = pixels[row * w * 4:(row + 1) * w * 4]
            break
        if message == 2:  # Bell.
            continue
        if message == 3:  # Clipboard text.
            receive(sock, 3)
            receive(sock, struct.unpack('>I', receive(sock, 4))[0])
            continue
        raise RuntimeError(f'Unexpected VNC message type {message}')

rgb = bytearray(width * height * 3)
rgb[0::3], rgb[1::3], rgb[2::3] = screen[2::4], screen[1::4], screen[0::4]
write_png('/tmp/desktop-screen.png', width, height, bytes(rgb))
colours = {bytes(rgb[i:i + 3]) for i in range(0, len(rgb), 3 * 97)}
print(f'VNC let me in with no password; {width}x{height} screen, {len(colours)} colours sampled.')
# A bare screen with one terminal window on it has few colours: the black
# background, the window, and the greys of smoothed text. A blank screen has one.
assert len(colours) >= 6, 'The screen is blank or not drawn'
