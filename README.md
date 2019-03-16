# crunch

This is a command line tool that will pack a bunch of images into a single, larger image. It was designed for [Celeste](http://www.celestegame.com/), but could be very helpful for other games.

It is designed using libraries with permissible licenses, so you are able to use it freely in your commercial and non-commercial projects. Please see each source file for its respective copyright and license.

### Features

- Export XML, JSON, or binary data
- Trim excess transparency
- Rotate images to fit
- Control atlas size and padding
- Premultiply pixel values
- Recursively scans folders
- Remove duplicate images
- Caching to prevent redundant builds
- Multi-image atlas when the sprites don't fit

### What does it do?

Given a folder with several images, like so:

```
images/
    player.png
    tree.png
    enemy.png
```

It will output something like this:

```
bin/
    images.png
    images.xml
    images.hash
```

Where `images.png` is the packed image, `images.xml` is an xml file describing where each sub-image is located, and `images.hash` is used for file caching (if none of the input files have changed since the last pack, the program will terminate).

There is also an option to use a binary format instead of xml.

### Usage

`crunch [OUTPUT] [INPUT1,INPUT2,INPUT3...] [OPTIONS...]`

For example...

`crunch bin/atlases/atlas assets/characters,assets/tiles -p -t -v -u -r -j`

This will output the following files:

```
bin/atlases/atlas.png
bin/atlases/atlas.json
bin/atlases/atlas.hash
```

### Options

| option        | alias         | description |
| ------------- | ------------- | ------------|
| -d            | --default     | use default settings (-x -p -t -u) |
| -x            | --xml         | saves the atlas data as a .xml file |
| -b            | --binary      | saves the atlas data as a .bin file |
| -c            | --compact     | saves the atlas data as a .bin file (with extra metadata and optimized for fast reading) |
| -j            | --json        | saves the atlas data as a .json file |
| -p            | --premultiply | premultiplies the pixels of the bitmaps by their alpha channel |
| -t            | --trim        | trims excess transparency off the bitmaps |
| -v            | --verbose     | print to the debug console as the packer works |
| -f            | --force       | ignore caching, forcing the packer to repack |
| -u            | --unique      | remove duplicate bitmaps from the atlas |
| -r            | --rotate      | enabled rotating bitmaps 90 degrees clockwise when packing |
| -s#           | --size#       | max atlas size (# can be 4096, 2048, 1024, 512, 256, 128, or 64) |
| -p#           | --pad#        | padding between images (# can be from 0 to 16) |
| -ba#          | --balign#     | align binary output (# can be 4096, 2048, 1024, 512, 256, 128 or 64) |

### Binary Format

The `--compact` switch adds this additional preamble containing magic number and version
```
(not in --binary output)
63 72 6E C7 49 31 5B  magic number ("crn\xC7I1[")
00                    format version number. Unsupported versions must be considered unknown.
                      Only a format change should change this version number.

[int16] alignment
[int16] size
[byte] padding
[byte] crunch_flags
```

crunch_flags:
- 0x01 premultiplied
- 0x02 trim enabled
- 0x04 rotation enabled
- 0x08 unique

the 2 most significant bits can be used for any user data and will not be written by crunch.

Additionally `--compact` sorts (ascending, ordinal) images by img_name. Binary will also do so if generated with a version of the tool supporting `--compact`, however specifying compact should be preferred.

```
[int16] num_textures (below block is repeated this many times)
        [string] name (sorted)
        [int16] num_images (below block is repeated this many times)
        // with --compact this is padded to the next 512 bytes (if not on one already)
            [string] img_name (not in --compact)
            [int16] img_x
            [int16] img_y
            [int16] img_width
            [int16] img_height
            [int16] img_frame_x         (if --trim enabled)
            [int16] img_frame_y         (if --trim enabled)
            [int16] img_frame_width     (if --trim enabled)
            [int16] img_frame_height    (if --trim enabled)
            [byte] img_rotated          (if --rotate enabled)
            [string] img_name (only in --compact, moved to end)
            // with --compact each image is padded to specified bytes (and must not exceed that in size)
```

Type notes:
- strings are null-terminated in --binary
- strings are length prefixed (2 byte length) without null-terminator in `--compact`
- numbers are little-endian encoded

### License

Unless otherwise specified in a source file, everything in this project falls under the following license:

```
MIT License

Copyright (c) 2017 Chevy Ray Johnston

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

The D reading library (being files dub.sdl and reader/d/crunch.d) is separately licensed as public domain.
