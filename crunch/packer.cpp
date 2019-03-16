/*
 
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
 
 */

#include "packer.hpp"
#include "MaxRectsBinPack.h"
#include "GuillotineBinPack.h"
#include "binary.hpp"
#include <iostream>
#include <algorithm>

using namespace std;
using namespace rbp;

Packer::Packer(int width, int height, int pad)
: width(width), height(height), pad(pad)
{
    
}

void Packer::Pack(vector<Bitmap*>& bitmaps, bool verbose, bool unique, bool rotate)
{
    MaxRectsBinPack packer(width, height);
    
    int ww = 0;
    int hh = 0;
    while (!bitmaps.empty())
    {
        auto bitmap = bitmaps.back();
        
        if (verbose)
            cout << '\t' << bitmaps.size() << ": " << bitmap->name << endl;
        
        //Check to see if this is a duplicate of an already packed bitmap
        if (unique)
        {
            auto di = dupLookup.find(bitmap->hashValue);
            if (di != dupLookup.end() && bitmap->Equals(this->bitmaps[di->second]))
            {
                Point p = points[di->second];
                p.dupID = di->second;
                points.push_back(p);
                this->bitmaps.push_back(bitmap);
                bitmaps.pop_back();
                continue;
            }
        }
        
        //If it's not a duplicate, pack it into the atlas
        {
            Rect rect = packer.Insert(bitmap->width + pad, bitmap->height + pad, rotate, MaxRectsBinPack::RectBestShortSideFit);
            
            if (rect.width == 0 || rect.height == 0)
                break;
            
            if (unique)
                dupLookup[bitmap->hashValue] = static_cast<int>(points.size());
            
            //Check if we rotated it
            Point p;
            p.x = rect.x;
            p.y = rect.y;
            p.dupID = -1;
            p.rot = rotate && bitmap->width != (rect.width - pad);
            
            points.push_back(p);
            this->bitmaps.push_back(bitmap);
            bitmaps.pop_back();
            
            ww = max(rect.x + rect.width, ww);
            hh = max(rect.y + rect.height, hh);
        }
    }
    
    while (width / 2 >= ww)
        width /= 2;
    while( height / 2 >= hh)
        height /= 2;
}

void Packer::SavePng(const string& file)
{
    Bitmap bitmap(width, height);
    for (size_t i = 0, j = bitmaps.size(); i < j; ++i)
    {
        if (points[i].dupID < 0)
        {
            if (points[i].rot)
                bitmap.CopyPixelsRot(bitmaps[i], points[i].x, points[i].y);
            else
                bitmap.CopyPixels(bitmaps[i], points[i].x, points[i].y);
        }
    }
    bitmap.SaveAs(file);
}

void Packer::SaveXml(const string& name, ofstream& xml, bool trim, bool rotate)
{
    xml << "\t<tex n=\"" << name << "\">" << endl;
    for (size_t i = 0, j = bitmaps.size(); i < j; ++i)
    {
        xml << "\t\t<img n=\"" << bitmaps[i]->name << "\" ";
        xml << "x=\"" << points[i].x << "\" ";
        xml << "y=\"" << points[i].y << "\" ";
        xml << "w=\"" << bitmaps[i]->width << "\" ";
        xml << "h=\"" << bitmaps[i]->height << "\" ";
        if (trim)
        {
            xml << "fx=\"" << bitmaps[i]->frameX << "\" ";
            xml << "fy=\"" << bitmaps[i]->frameY << "\" ";
            xml << "fw=\"" << bitmaps[i]->frameW << "\" ";
            xml << "fh=\"" << bitmaps[i]->frameH << "\" ";
        }
        if (rotate)
            xml << "r=\"" << (points[i].rot ? 1 : 0) << "\" ";
        xml << "/>" << endl;
    }
    xml << "\t</tex>" << endl;
}

void Packer::SaveBin(const string& name, ofstream& bin, bool trim, bool rotate, int version, int alignment)
{
    auto p = sort_permutation(bitmaps, [](const Bitmap* a, const Bitmap* b) -> bool
    {
        return a->name.compare(b->name) < 0;
    });
    apply_permutation_in_place(bitmaps, p);
    apply_permutation_in_place(points, p);

    WriteStringVersion(bin, name, version);
    WriteShort(bin, static_cast<int16_t>(bitmaps.size()));

    if (version >= 0)
        alignStream(bin, alignment);

    for (size_t i = 0, j = bitmaps.size(); i < j; ++i)
    {
        // short name length + name + 4x short, + trim ? 4x short + rotate ? 1
        if (version >= 0 && 2 + bitmaps[i]->name.length() + 8 + (trim ? 8 : 0) + (rotate ? 1 : 0) > alignment)
        {
            cerr << "Skipping file in binary output (name too long, try specifying bigger --balign): " << bitmaps[i]->name << endl;
            continue; // skip too big
        }

        if (version == -1)
            WriteString(bin, bitmaps[i]->name);

        WriteShort(bin, static_cast<int16_t>(points[i].x));
        WriteShort(bin, static_cast<int16_t>(points[i].y));
        WriteShort(bin, static_cast<int16_t>(bitmaps[i]->width));
        WriteShort(bin, static_cast<int16_t>(bitmaps[i]->height));
        if (trim)
        {
            WriteShort(bin, static_cast<int16_t>(bitmaps[i]->frameX));
            WriteShort(bin, static_cast<int16_t>(bitmaps[i]->frameY));
            WriteShort(bin, static_cast<int16_t>(bitmaps[i]->frameW));
            WriteShort(bin, static_cast<int16_t>(bitmaps[i]->frameH));
        }
        if (rotate)
            WriteByte(bin, points[i].rot ? 1 : 0);

        if (version >= 0)
        {
            WriteLengthPrefixedString(bin, bitmaps[i]->name);

            alignStream(bin, alignment);
        }
    }
}

void Packer::SaveJson(const string& name, ofstream& json, bool trim, bool rotate)
{
    json << "\t\t\t\"name\":\"" << name << "\"," << endl;
    json << "\t\t\t\"images\":[" << endl;
    for (size_t i = 0, j = bitmaps.size(); i < j; ++i)
    {
        json << "\t\t\t\t{ ";
        json << "\"n\":\"" << bitmaps[i]->name << "\", ";
        json << "\"x\":" << points[i].x << ", ";
        json << "\"y\":" << points[i].y << ", ";
        json << "\"w\":" << bitmaps[i]->width << ", ";
        json << "\"h\":" << bitmaps[i]->height;
        if (trim)
        {
            json << ", \"fx\":" << bitmaps[i]->frameX << ", ";
            json << "\"fy\":" << bitmaps[i]->frameY << ", ";
            json << "\"fw\":" << bitmaps[i]->frameW << ", ";
            json << "\"fh\":" << bitmaps[i]->frameH;
        }
        if (rotate)
            json << ", \"r\":" << (points[i].rot ? "true" : "false");
        json << " }";
        if(i != bitmaps.size() -1)
            json << ",";
        json << endl;
    }
    json << "\t\t\t]" << endl;
}

void alignStream(ofstream& bin, int alignment)
{
    static const char zeros[4096] = "";

    assert(alignment <= 4096);

    streampos position = bin.tellp();
    streampos remaining = alignment - (position % alignment);
    if (position >= 0 && remaining > 0)
    {
        bin.write(&zeros[0], remaining);
    }
}

// https://stackoverflow.com/questions/17074324/how-can-i-sort-two-vectors-in-the-same-way-with-criteria-that-uses-only-one-of
template <typename T, typename Compare>
std::vector<std::size_t> sort_permutation(
    const std::vector<T>& vec,
    Compare compare)
{
    std::vector<std::size_t> p(vec.size());
    std::iota(p.begin(), p.end(), 0);
    std::sort(p.begin(), p.end(),
        [vec, compare](std::size_t i, std::size_t j){ return compare(vec[i], vec[j]); });
    return p;
}

template <typename T>
void apply_permutation_in_place(
    std::vector<T>& vec,
    const std::vector<std::size_t>& p)
{
    std::vector<bool> done(vec.size());
    for (std::size_t i = 0; i < vec.size(); ++i)
    {
        if (done[i])
        {
            continue;
        }
        done[i] = true;
        std::size_t prev_j = i;
        std::size_t j = p[i];
        while (i != j)
        {
            std::swap(vec[prev_j], vec[j]);
            done[j] = true;
            prev_j = j;
            j = p[j];
        }
    }
}
