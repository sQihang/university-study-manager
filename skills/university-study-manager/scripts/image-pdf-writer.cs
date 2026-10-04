// Minimal JPEG-only PDF writer. No PDF parser and no external packages.
using System;
using System.IO;
using System.Text;
using System.Globalization;
using System.Collections.Generic;

namespace StudyDocuments {
    public sealed class ImagePdfWriter : IDisposable {
        private FileStream stream;
        private Dictionary<int,long> offsets = new Dictionary<int,long>();
        private List<int> pages = new List<int>();
        private bool finished;
        public int PageCount { get { return pages.Count; } }
        public long EstimatedSizeAfter(long jpegBytes) {
            return stream.Position + jpegBytes + (pages.Count + 1L) * 4096L + 8192L;
        }
        public ImagePdfWriter(string path) {
            stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            Write("%PDF-1.4\n% Image-only document\n");
        }
        private void Write(string value) {
            byte[] data = Encoding.ASCII.GetBytes(value);
            stream.Write(data, 0, data.Length);
        }
        private void Object(int id) { offsets[id] = stream.Position; Write(id + " 0 obj\n"); }
        private static int U16(Stream source) {
            int a = source.ReadByte(), b = source.ReadByte();
            if (a < 0 || b < 0) throw new InvalidDataException();
            return a * 256 + b;
        }
        public static int[] JpegInfo(string path) {
            using (FileStream source = File.OpenRead(path)) {
                if (source.ReadByte() != 255 || source.ReadByte() != 216) throw new InvalidDataException();
                while (source.Position < source.Length) {
                    if (source.ReadByte() != 255) throw new InvalidDataException();
                    int marker;
                    do { marker = source.ReadByte(); } while (marker == 255);
                    if (marker == 217 || marker == 218 || marker < 0) throw new InvalidDataException();
                    if (marker == 216 || marker == 1 || (marker >= 208 && marker <= 215)) continue;
                    int length = U16(source);
                    if (length < 2 || source.Position + length - 2 > source.Length) throw new InvalidDataException();
                    if (marker == 192 || marker == 193 || marker == 194) {
                        int bits = source.ReadByte();
                        int height = U16(source), width = U16(source), components = source.ReadByte();
                        if (bits != 8 || width < 1 || height < 1 || (components != 1 && components != 3)) throw new InvalidDataException();
                        return new int[] {width, height, components};
                    }
                    source.Seek(length - 2, SeekOrigin.Current);
                }
            }
            throw new InvalidDataException();
        }
        public void AddPage(string jpegPath, int dpi) {
            if (finished || dpi <= 0) throw new InvalidOperationException();
            int[] info = JpegInfo(jpegPath);
            string width = (info[0] * 72.0 / dpi).ToString("0.####", CultureInfo.InvariantCulture);
            string height = (info[1] * 72.0 / dpi).ToString("0.####", CultureInfo.InvariantCulture);
            int page = 3 + pages.Count * 3, image = page + 1, content = page + 2;
            Object(page);
            Write("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 " + width + " " + height + "] /Resources << /XObject << /Im0 " + image + " 0 R >> >> /Contents " + content + " 0 R >>\nendobj\n");
            using (FileStream jpeg = File.OpenRead(jpegPath)) {
                Object(image);
                Write("<< /Type /XObject /Subtype /Image /Width " + info[0] + " /Height " + info[1] + " /ColorSpace /" + (info[2] == 3 ? "DeviceRGB" : "DeviceGray") + " /BitsPerComponent 8 /Filter /DCTDecode /Length " + jpeg.Length + " >>\nstream\n");
                jpeg.CopyTo(stream);
                Write("\nendstream\nendobj\n");
            }
            string drawing = "q\n" + width + " 0 0 " + height + " 0 0 cm\n/Im0 Do\nQ\n";
            Object(content);
            Write("<< /Length " + Encoding.ASCII.GetByteCount(drawing) + " >>\nstream\n" + drawing + "endstream\nendobj\n");
            pages.Add(page);
        }
        public void Finish() {
            if (finished || pages.Count == 0) throw new InvalidOperationException();
            Object(1); Write("<< /Type /Catalog /Pages 2 0 R >>\nendobj\n");
            Object(2); Write("<< /Type /Pages /Count " + pages.Count + " /Kids [");
            foreach (int page in pages) Write(page + " 0 R ");
            Write("] >>\nendobj\n");
            long xref = stream.Position;
            int count = 3 + pages.Count * 3;
            Write("xref\n0 " + count + "\n0000000000 65535 f \n");
            for (int id = 1; id < count; id++) Write(offsets[id].ToString("D10", CultureInfo.InvariantCulture) + " 00000 n \n");
            Write("trailer\n<< /Size " + count + " /Root 1 0 R >>\nstartxref\n" + xref.ToString(CultureInfo.InvariantCulture) + "\n%%EOF\n");
            stream.Flush(); finished = true;
        }
        public void Dispose() { if (stream != null) { stream.Dispose(); stream = null; } }
    }
}
