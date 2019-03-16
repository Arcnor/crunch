/// Provides a reading library for crunch texture packing files.
/// License: public domain
module crunch;

import std.algorithm;
import std.bitmanip;
import std.conv;
import std.json;
import std.parallelism;
import std.range;

import std.xml;

static immutable string ImageSorter = "a.name < b.name";

///
struct Crunch
{
	///
	static immutable string magicNumber = "crn\xC7I1[";

	///
	enum Flags : ubyte
	{
		none = 0,
		premultiplied = 1 << 0,
		trimEnabled = 1 << 1,
		rotationEnabled = 1 << 2,
		unique = 1 << 3,
	}

	/// Represents a source image that got packed.
	struct Image
	{
		/// Original name of the source image without extension.
		string name;
		/// Rectangle in the texture where to find this image.
		ushort x, y, width, height;
		/// Offset where texture would be with additional transparency. Can be negative.
		short frameX, frameY;
		/// Actual size how big texture would be with transparency.
		ushort frameWidth, frameHeight;
		/// True if rotated by 90 degrees (clockwise).
		bool rotated;
	}

	/// Represents a single png containing a set of packed images.
	struct Texture
	{
		/// Texture filename
		string name;
		/// Sorted list of images mapped in this texture
		Image[] images;
	}

	/// Information about all generated textures
	Texture[] textures;

	/// What size was passed to crunch when packing
	ushort textureSize;
	/// Amount of padding between textures
	byte padding;
	/// Further flags passed into crunch
	Flags flags;

	/// Finds an image by name in the textures with sorted image lists
	Image* find(string name)
	{
		foreach (ref tex; textures)
		{
			auto images = assumeSorted!ImageSorter(tex.images);

			auto match = images.trisect(Image(name));

			if (match[1].length)
				return &tex.images[match[0].length];
		}

		return null;
	}
}

/// Parses a crunch file from --compact or --binary output. For old --binary format files no trim and no rotate is assumed.
/// Params:
///     data = binary data to parse
///     allowBinary = true to make a failed magicnumber check interpret the file as --binary output (no metadata)
///     nameDup = method to duplicate names of textures and images. Must be the input name because it is sorted.
Crunch crunchFromCompact(alias nameDup)(const ubyte[] data, bool allowBinary)
{
	Crunch ret;

	size_t i;
	ushort alignment;
	int ver = -1;

	if (data.length < 8 || data[0 .. Crunch.magicNumber.length] != Crunch.magicNumber)
	{
		if (!allowBinary)
			throw new Exception("Passed data is not a crunch file");
	}
	else
	{
		i += Crunch.magicNumber.length;
		ver = data.peek!ubyte(&i);

		if (ver != 0)
			throw new Exception(text("Unsupported crunch version: ", ver));

		if (i + 6 > data.length)
			throw new Exception("Invalid file, not enough data");

		alignment = data.peek!(ushort, Endian.littleEndian)(&i);
		ret.textureSize = data.peek!(ushort, Endian.littleEndian)(&i);
		ret.padding = data.peek!ubyte(&i);
		ret.flags = cast(Crunch.Flags) data.peek!ubyte(&i);
	}

	ushort numTextures = data.peek!(ushort, Endian.littleEndian)(&i);

	ret.textures.length = numTextures;
	foreach (ref texture; ret.textures)
	{
		texture.name = nameDup(data.readString(&i, ver));
		ushort num = data.peek!(ushort, Endian.littleEndian)(&i);
		texture.images.length = num;

		if (ver == -1)
		{
			foreach (n; 0 .. num)
			{
				texture.images[n].name = nameDup(data.readString(&i, ver));
				texture.images[n].x = data.peek!(ushort, Endian.littleEndian)(&i);
				texture.images[n].y = data.peek!(ushort, Endian.littleEndian)(&i);
				texture.images[n].width = texture.images[n].frameWidth = data.peek!(ushort,
						Endian.littleEndian)(&i);
				texture.images[n].height = texture.images[n].frameHeight = data.peek!(ushort,
						Endian.littleEndian)(&i);
			}

			texture.images.sort!ImageSorter;
		}
		else
		{
			const size_t base = i = alignNumber(i, alignment);
			i += num * alignment;
			foreach (n; iota(num).parallel)
			{
				size_t index = base + n * alignment;

				texture.images[n] = data.crunchImageFromCompactNoName(ret.flags, &index);
				texture.images[n].name = nameDup(data.readString(&index, ver));
			}
		}
	}

	return ret;
}

/// Parses a crunch file from --compact output. Uses the GC .idup to make strings
Crunch crunchFromCompact(ubyte[] data, bool allowBinary)
{
	return crunchFromCompact!(name => name.idup)(data, allowBinary);
}

private Crunch.Image crunchImageFromCompactNoName(const ubyte[] data,
		Crunch.Flags flags, size_t* index)
{
	Crunch.Image ret;
	ret.x = data.peek!(ushort, Endian.littleEndian)(index);
	ret.y = data.peek!(ushort, Endian.littleEndian)(index);
	ret.width = ret.frameWidth = data.peek!(ushort, Endian.littleEndian)(index);
	ret.height = ret.frameHeight = data.peek!(ushort, Endian.littleEndian)(index);
	if ((flags & Crunch.Flags.trimEnabled) == Crunch.Flags.trimEnabled)
	{
		ret.frameX = data.peek!(ushort, Endian.littleEndian)(index);
		ret.frameY = data.peek!(ushort, Endian.littleEndian)(index);
		ret.frameWidth = data.peek!(ushort, Endian.littleEndian)(index);
		ret.frameHeight = data.peek!(ushort, Endian.littleEndian)(index);
	}
	if ((flags & Crunch.Flags.rotationEnabled) == Crunch.Flags.rotationEnabled)
		ret.rotated = data.peek!ubyte(index) != 0;
	return ret;
}

/// Finds one image in a compact file efficiently. Returns Crunch.Image.init when it couldn't be found.
Crunch.Image searchInCompact(ubyte[] data, string name, out int textureIndex)
{
	size_t i;
	ushort alignment;

	if (data.length < 8 || data[0 .. Crunch.magicNumber.length] != Crunch.magicNumber)
	{
		throw new Exception("Passed data is not a crunch file");
	}
	i += Crunch.magicNumber.length;
	const int ver = data.peek!ubyte(&i);

	if (ver != 0)
		throw new Exception(text("Unsupported crunch version: ", ver));

	alignment = data.peek!(ushort, Endian.littleEndian)(&i);
	Crunch.Flags flags = cast(Crunch.Flags) data[i + 3];
	i += 4;

	size_t imageNameOffset = 8;
	if ((flags & Crunch.Flags.trimEnabled) == Crunch.Flags.trimEnabled)
		imageNameOffset += 8;
	if ((flags & Crunch.Flags.rotationEnabled) == Crunch.Flags.rotationEnabled)
		imageNameOffset += 1;

	ushort numTextures = data.peek!(ushort, Endian.littleEndian)(&i);
	foreach (n; 0 .. numTextures)
	{
		data.readString(&i, ver);
		ushort numImages = data.peek!(ushort, Endian.littleEndian)(&i);
		i = alignNumber(i, alignment);

		auto chunks = data[i .. i += numImages * alignment].chunks(alignment);
		auto sorted = chunks.map!((a) {
			size_t subIndex = imageNameOffset;
			return a.readString(&subIndex, ver);
		})
			.assumeSorted!"a < b";

		auto parts = sorted.trisect(name);
		if (parts[1].length)
		{
			textureIndex = n;
			size_t index = 0;
			auto ret = crunchImageFromCompactNoName(chunks[parts[0].length], flags, &index);
			ret.name = name;
			return ret;
		}
	}

	return Crunch.Image.init;
}

private char[] readString(const ubyte[] data, size_t* i, int ver)
{
	static char[256] shortBuffer;

	if (ver == -1)
	{
		int n = 0;
		while (data[*i] != 0)
		{
			shortBuffer[n++] = data[*i];
			i++;
		}
		i++;

		return cast(char[]) shortBuffer[0 .. n];
	}
	else
	{
		ushort size = data.peek!(ushort, Endian.littleEndian)(i);
		return cast(char[]) data[*i .. *i += size];
	}
}

private size_t alignNumber(size_t n, size_t alignment)
{
	alignment--;
	return (n + alignment) & ~alignment;
}

/// Reads a crunch file from json (either old or new format)
Crunch crunchFromJson(JSONValue json)
{
	if (json.type != JSONType.object)
		throw new Exception("JSON is not an object");

	Crunch ret;

	auto ver = "version" in json ? json["version"].integer : 0;
	if (ver == 0)
	{
		// no metadata, we can just guess trim and rotate
	}
	else if (ver == 1)
	{
		ret.textureSize = cast(ushort) json["size"].integer;
		ret.padding = cast(byte) json["padding"].integer;
		if (json["premultiplied"].boolean)
			ret.flags |= Crunch.Flags.premultiplied;
		if (json["trim"].boolean)
			ret.flags |= Crunch.Flags.trimEnabled;
		if (json["rotate"].boolean)
			ret.flags |= Crunch.Flags.rotationEnabled;
		if (json["unique"].boolean)
			ret.flags |= Crunch.Flags.unique;
	}
	else
		throw new Exception("Unsupported JSON version");

	auto textures = json["textures"].array;
	ret.textures.length = textures.length;
	foreach (i, texture; textures)
	{
		ret.textures[i].name = texture["name"].str;
		auto images = texture["images"].array;
		ret.textures[i].images.length = images.length;
		foreach (j, image; images)
		{
			ret.textures[i].images[j].name = image["n"].str;
			ret.textures[i].images[j].x = cast(ushort) image["x"].integer;
			ret.textures[i].images[j].y = cast(ushort) image["y"].integer;
			ret.textures[i].images[j].width = ret.textures[i].images[j].frameWidth = cast(
					ushort) image["w"].integer;
			ret.textures[i].images[j].height = ret.textures[i].images[j].frameHeight = cast(
					ushort) image["h"].integer;

			if ("fx" in image)
			{
				ret.flags |= Crunch.Flags.trimEnabled;
				ret.textures[i].images[j].frameX = cast(short) image["fx"].integer;
				ret.textures[i].images[j].frameY = cast(short) image["fy"].integer;
				ret.textures[i].images[j].frameWidth = cast(ushort) image["fw"].integer;
				ret.textures[i].images[j].frameHeight = cast(ushort) image["fh"].integer;
			}

			if (auto rot = "r" in image)
			{
				ret.flags |= Crunch.Flags.rotationEnabled;
				ret.textures[i].images[j].rotated = rot.boolean;
			}
		}

		ret.textures[i].images.sort!ImageSorter;
	}

	return ret;
}

/// Parses an xml file for crunch. Uses std.xml so it might get deprecated eventually.
Crunch crunchFromXml(string xmlStr)
{
	Crunch ret;

	auto xml = new DocumentParser(xmlStr);
	xml.onStartTag["tex"] = (ElementParser xml) {
		Crunch.Texture texture;
		texture.name = xml.tag.attr["n"];

		xml.onStartTag["img"] = (ElementParser xml) {
			Crunch.Image image;
			image.name = xml.tag.attr["n"];
			image.x = cast(ushort) xml.tag.attr["x"].to!int;
			image.y = cast(ushort) xml.tag.attr["y"].to!int;
			image.width = image.frameWidth = cast(ushort) xml.tag.attr["w"].to!int;
			image.height = image.frameHeight = cast(ushort) xml.tag.attr["h"].to!int;
			if ("fx" in xml.tag.attr)
			{
				ret.flags |= Crunch.Flags.trimEnabled;
				image.frameX = cast(short) xml.tag.attr["fx"].to!int;
				image.frameY = cast(short) xml.tag.attr["fy"].to!int;
				image.frameWidth = cast(ushort) xml.tag.attr["fw"].to!int;
				image.frameHeight = cast(ushort) xml.tag.attr["fh"].to!int;
			}
			if (auto rot = "r" in xml.tag.attr)
			{
				ret.flags |= Crunch.Flags.rotationEnabled;
				image.rotated = rot.length && *rot != "0";
			}
			texture.images ~= image;
		};

		xml.parse();

		texture.images.sort!ImageSorter;
		ret.textures ~= texture;
	};

	auto rootAttrs = xml.tag.attr;
	if ("premultiplied" in rootAttrs)
		ret.flags |= Crunch.Flags.premultiplied;
	if ("trim" in rootAttrs)
		ret.flags |= Crunch.Flags.trimEnabled;
	if ("rotate" in rootAttrs)
		ret.flags |= Crunch.Flags.rotationEnabled;
	if ("unique" in rootAttrs)
		ret.flags |= Crunch.Flags.unique;

	if (auto size = "size" in rootAttrs)
		ret.textureSize = cast(ushort)(*size).to!int;
	if (auto padding = "padding" in rootAttrs)
		ret.padding = cast(byte)(*padding).to!int;

	xml.parse();

	return ret;
}

unittest
{
	auto dat = crunchFromXml(q{<?xml version="1.0"?>
		<atlas version="1" size="2048" padding="1" trim="trim" rotate="rotate" unique="unique">
			<tex n="packed0">
				<img n="sprGameOver_0" x="0" y="0" w="757" h="158" fx="0" fy="0" fw="757" fh="158" r="0" />
				<img n="bStars" x="757" y="0" w="256" h="256" fx="0" fy="0" fw="256" fh="256" r="1" />
			</tex>
			<tex n="packed1">
				<img n="sprPlayer" x="40" y="40" w="32" h="64" fx="-5" fy="-2" fw="40" fh="80" r="0" />
				<img n="bGrass" x="757" y="0" w="256" h="256" fx="0" fy="0" fw="256" fh="256" r="0" />
			</tex>
		</atlas>});

	auto json = crunchFromJson(parseJSON(q{{
		"version": 1,
		"size": 2048,
		"padding": 1,
		"premultiplied": false,
		"trim": true,
		"rotate": true,
		"unique": true,
		"textures":[
			{
				"name":"packed0",
				"images":[
					{ "n":"sprGameOver_0", "x":0, "y":0, "w":757, "h":158, "fx":0, "fy":0, "fw":757, "fh":158, "r":false },
					{ "n":"bStars", "x":757, "y":0, "w":256, "h":256, "fx":0, "fy":0, "fw":256, "fh":256, "r":true }
				]
			},
			{
				"name":"packed1",
				"images":[
					{ "n":"sprPlayer", "x":40, "y":40, "w":32, "h":64, "fx":-5, "fy":-2, "fw":40, "fh":80, "r":false },
					{ "n":"bGrass", "x":757, "y":0, "w":256, "h":256, "fx":0, "fy":0, "fw":256, "fh":256, "r":false }
				]
			}
		]
	}}));

	//dfmt off
	auto bin = crunchFromCompact(cast(ubyte[])(
			hexString!"63 72 6E C7 49 31 5B 00" ~ // magic number
			hexString!"40 00 00 08 01 0E 02 00" ~ // align, size, padding, flags, num textures
			hexString!"07 00 70 61 63 6B 65 64 30 02 00 00 00 00 00 00" ~ // packed0, 0 entries
			hexString!"00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00" ~ //
			hexString!"00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00" ~ //
			hexString!"F5 02 00 00 00 01 00 01 00 00 00 00 00 01 00 01" ~ // entry 1
			hexString!"01 06 00 62 53 74 61 72 73 00 00 00 00 00 00 00" ~ //
			hexString!"00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00" ~ //
			hexString!"00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00" ~ //
			hexString!"00 00 00 00 F5 02 9E 00 00 00 00 00 F5 02 9E 00" ~ // entry 2
			hexString!"00 0D 00 73 70 72 47 61 6d 65 4f 76 65 72 5f 30" ~ //
			hexString!"00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00" ~ //
			hexString!"00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00" ~ //
			hexString!"07 00 70 61 63 6B 65 64 31 02 00 00 00 00 00 00" ~ // packed1, 0 entries
			hexString!"00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00" ~ //
			hexString!"00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00" ~ //
			hexString!"00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00" ~ //
			hexString!"F5 02 00 00 00 01 00 01 00 00 00 00 00 01 00 01" ~ // entry 1
			hexString!"00 06 00 62 47 72 61 73 73 00 00 00 00 00 00 00" ~ //
			hexString!"00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00" ~ //
			hexString!"00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00" ~ //
			hexString!"28 00 28 00 20 00 40 00 FB FF FE FF 28 00 50 00" ~ // entry 2
			hexString!"00 09 00 73 70 72 50 6c 61 79 65 72 00 00 00 00" ~ //
			hexString!"00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00" ~ //
			hexString!"00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"), false);
	//dfmt on

	assert(dat.textureSize == 2048);
	assert(dat.padding == 1);
	assert(dat.flags == (Crunch.Flags.trimEnabled | Crunch.Flags.rotationEnabled | Crunch.Flags.unique),
			dat.flags.to!string);
	assert(dat.textures.length == 2);

	assert(dat.textures[0].name == "packed0");
	assert(dat.textures[0].images.length == 2);

	assert(dat.textures[0].images[0].name == "bStars");
	assert(dat.textures[0].images[0].x == 757);
	assert(dat.textures[0].images[0].y == 0);
	assert(dat.textures[0].images[0].width == 256);
	assert(dat.textures[0].images[0].height == 256);
	assert(dat.textures[0].images[0].frameX == 0);
	assert(dat.textures[0].images[0].frameY == 0);
	assert(dat.textures[0].images[0].frameWidth == 256);
	assert(dat.textures[0].images[0].frameHeight == 256);
	assert(dat.textures[0].images[0].rotated);

	assert(dat.textures[0].images[1].name == "sprGameOver_0");
	assert(dat.textures[0].images[1].x == 0);
	assert(dat.textures[0].images[1].y == 0);
	assert(dat.textures[0].images[1].width == 757);
	assert(dat.textures[0].images[1].height == 158);
	assert(dat.textures[0].images[1].frameX == 0);
	assert(dat.textures[0].images[1].frameY == 0);
	assert(dat.textures[0].images[1].frameWidth == 757);
	assert(dat.textures[0].images[1].frameHeight == 158);
	assert(!dat.textures[0].images[1].rotated);

	assert(dat.textures[1].name == "packed1");
	assert(dat.textures[1].images.length == 2);

	assert(dat.textures[1].images[0].name == "bGrass");
	assert(dat.textures[1].images[0].x == 757);
	assert(dat.textures[1].images[0].y == 0);
	assert(dat.textures[1].images[0].width == 256);
	assert(dat.textures[1].images[0].height == 256);
	assert(dat.textures[1].images[0].frameX == 0);
	assert(dat.textures[1].images[0].frameY == 0);
	assert(dat.textures[1].images[0].frameWidth == 256);
	assert(dat.textures[1].images[0].frameHeight == 256);
	assert(!dat.textures[1].images[0].rotated);

	assert(dat.textures[1].images[1].name == "sprPlayer");
	assert(dat.textures[1].images[1].x == 40);
	assert(dat.textures[1].images[1].y == 40);
	assert(dat.textures[1].images[1].width == 32);
	assert(dat.textures[1].images[1].height == 64);
	assert(dat.textures[1].images[1].frameX == -5);
	assert(dat.textures[1].images[1].frameY == -2);
	assert(dat.textures[1].images[1].frameWidth == 40);
	assert(dat.textures[1].images[1].frameHeight == 80);
	assert(!dat.textures[1].images[1].rotated);

	assert(dat == json);
	assert(dat == bin);
}
