cimport ogg, vorbis

cimport cpython.mem
cimport cpython.exc

cimport cython
from cython cimport parallel

from libc cimport stdio
from libc.errno cimport errno
from libc.string cimport memcpy

cdef object time
from time import time

cdef object sys
import sys

__version__ = "0.2"


class VorbisException(Exception):
    pass

class VorbisDecodeException(VorbisException):
    pass


DEF READ_BUFFER_SIZE = 4 * (256 * 1024)  # 256K samples of 2 bytes stereo

cdef vorbis.ov_callbacks filelike_callbacks
filelike_callbacks.read_func  = _readFilelike
filelike_callbacks.seek_func  = _seekFilelike
filelike_callbacks.tell_func  = _tellFilelike
filelike_callbacks.close_func = _closeFilelike


cdef int _checkVorbisResult(int result_code) except -1:
    if result_code < 0:
        raise VorbisException()
    return 0

cdef bytes _encodeFilename(filename):
    if isinstance(filename, bytes):
        return <bytes>filename
    elif isinstance(filename, unicode):
        encoding = sys.getfilesystemencoding()
        if not encoding:
            encoding = 'iso8859-1'  # just give it a try ...
        return (<unicode>filename).encode(encoding)
    else:
        raise ValueError("expected file path, got %s" % type(filename))


cdef class VorbisFile:
    cdef vorbis.OggVorbis_File _vorbisfile
    cdef object filename

    def __cinit__(self, filename):
        cdef stdio.FILE* cfile
        cdef int result
        filename = _encodeFilename(filename)
        cfile = stdio.fopen(filename, "r")
        if cfile is NULL:
            raise IOError("Opening file %r failed" % filename)
        result = vorbis.ov_test(cfile, &self._vorbisfile, NULL, 0)
        if result == 0:
            result = vorbis.ov_test_open(&self._vorbisfile)
        if result < 0:
            vorbis.ov_clear(&self._vorbisfile) # closes the file
            if result == vorbis.OV_ENOTVORBIS:
                raise VorbisException("%r is not a Vorbis file" % filename)
            raise IOError("Error reading from file %r" % filename)
        self.filename = filename

    def __dealloc__(self):
        if self.filename is not None:
            vorbis.ov_clear(&self._vorbisfile) # closes the file


ctypedef int (*page_writer_function)(void*, ogg.ogg_page*) nogil

cdef struct communication:   # thread communication
    int done
    int buffer_ready
    int next_buffer_ready
    long read_status[2]


cdef class _VorbisRecoder:
    cdef page_writer_function _write

    @cython.final
    cdef _recode(self, void* status, vorbis.OggVorbis_File* vorbisfile,
                 int target_quality):
        cdef int error_status, init_steps
        cdef float cquality
        cdef char* decbuffer = NULL
        cdef ogg.ogg_stream_state stream_state
        cdef vorbis.vorbis_info vorbis_info
        cdef vorbis.vorbis_dsp_state dsp_state
        cdef vorbis.vorbis_block vorbis_block

        if target_quality > 10:
            cquality = 1.0
        elif target_quality < -1:
            cquality = -0.1
        else:
            cquality = target_quality / 10.0

        # encoding setup
        vorbis.vorbis_info_init(&vorbis_info)
        error_status = vorbis.vorbis_encode_init_vbr(
            &vorbis_info, vorbisfile.vi.channels,
            vorbisfile.vi.rate, cquality)
        if not error_status:
            error_status = _initVorbisEncoder(
                &stream_state, &dsp_state, &vorbis_info,
                # use arbitrary but predictable serial number
                vorbisfile.current_serialno | <int>(cquality*10+2))
        if not error_status:
            vorbis.vorbis_block_init(&dsp_state, &vorbis_block)
            error_status = self._writeVorbisHeader(
                status, &stream_state, &dsp_state, vorbisfile.vc)

        t = time()
        try:
            if not error_status:
                decbuffer = <char*> cpython.mem.PyMem_Malloc(READ_BUFFER_SIZE*2)
                if decbuffer is NULL:
                    raise MemoryError()
                self._recodeParallel(
                    status, decbuffer, vorbisfile,
                    dsp_state, vorbis_block, stream_state)
        finally:
            ogg.ogg_stream_clear(&stream_state)
            vorbis.vorbis_block_clear(&vorbis_block)
            vorbis.vorbis_dsp_clear(&dsp_state)
            vorbis.vorbis_info_clear(&vorbis_info)
            cpython.mem.PyMem_Free(decbuffer)
            vorbis.ov_clear(vorbisfile) # closes the input file
        t = time() - t

        if error_status:
            raise VorbisException(
                "Unknown error %d occurred while preparing recoder" %
                error_status)

        return t

    @cython.final
    cdef _recodeParallel(self, void* status, char* decbuffer,
                         vorbis.OggVorbis_File* vorbisfile,
                         vorbis.vorbis_dsp_state dsp_state,
                         vorbis.vorbis_block vorbis_block,
                         ogg.ogg_stream_state stream_state
                         ):
        cdef long read_status, values_read
        cdef int i, eos, buffer_part, current_section
        cdef communication com   # thread communication

        com.read_status[0] = vorbis.ov_read(
            vorbisfile, decbuffer, READ_BUFFER_SIZE,
            0, 2, 1, &current_section)
        _checkVorbisResult(com.read_status[0])

        com.done = 0
        com.buffer_ready = 0

        with nogil, parallel.parallel(num_threads=2):
            while True:
                # using prange() loop to synchronise
                for i in parallel.prange(2):
                    if i == 1:
                        # reader thread
                        buffer_part = 0 if com.buffer_ready == 1 else 1
                        read_status = vorbis.ov_read(
                            vorbisfile,
                            decbuffer + (READ_BUFFER_SIZE * buffer_part),
                            READ_BUFFER_SIZE,
                            0, 2, 1, &current_section)
                        com.read_status[buffer_part] = read_status
                        com.next_buffer_ready = buffer_part
                    else:
                        # writer thread
                        buffer_part = com.buffer_ready
                        read_status = com.read_status[buffer_part]
                        encbuffer = vorbis.vorbis_analysis_buffer(
                            &dsp_state, READ_BUFFER_SIZE/4)
                        if read_status > 0:
                            values_read = read_status / 4
                            _splitStereo(
                                decbuffer + (READ_BUFFER_SIZE * buffer_part),
                                encbuffer[0], encbuffer[1], values_read)
                        else:
                            values_read = 0
                        vorbis.vorbis_analysis_wrote(&dsp_state, values_read)

                        eos = self._encodeVorbisBlocks(
                            status, &stream_state, &dsp_state,
                            &vorbis_block)
                        if eos:
                            com.done = 1
                if com.done:
                    break
                # switch buffers when both are done
                com.buffer_ready = com.next_buffer_ready

        read_status = com.read_status[com.buffer_ready]
        if read_status == vorbis.OV_HOLE or read_status == vorbis.OV_EBADLINK:
            raise VorbisDecodeException("lost sync")

    @cython.final
    cdef int _writeVorbisHeader(self, void* status,
                                 ogg.ogg_stream_state* stream_state,
                                 vorbis.vorbis_dsp_state* dsp_state,
                                 vorbis.vorbis_comment* comment):
        cdef ogg.ogg_packet header
        cdef ogg.ogg_packet header_comm
        cdef ogg.ogg_packet header_code
        cdef ogg.ogg_page   header_page
        cdef int result
        result = vorbis.vorbis_analysis_headerout(
            dsp_state, comment,
            &header, &header_comm, &header_code)
        if result < 0:
            return result
        if ogg.ogg_stream_packetin(stream_state, &header) < 0:
            return -1
        if ogg.ogg_stream_packetin(stream_state, &header_comm) < 0:
            return -1
        if ogg.ogg_stream_packetin(stream_state, &header_code) < 0:
            return -1

        result = ogg.ogg_stream_flush(stream_state, &header_page)
        while result > 0:
            result = self._write(status, &header_page)
            if result < 0:
                return result
            result = ogg.ogg_stream_flush(stream_state, &header_page)
        return 0

    @cython.final
    cdef int _encodeVorbisBlocks(self, void* status,
                                 ogg.ogg_stream_state* stream_state,
                                 vorbis.vorbis_dsp_state* dsp_state,
                                 vorbis.vorbis_block* vorbis_block) nogil:
        cdef int eos, error_status
        eos = 0
        error_status = vorbis.vorbis_analysis_blockout(dsp_state, vorbis_block)
        while error_status == 1:
            error_status = vorbis.vorbis_analysis(vorbis_block, NULL)
            if error_status < 0:
                return error_status
            error_status = vorbis.vorbis_bitrate_addblock(vorbis_block)
            if error_status < 0:
                return error_status
            error_status = self._writeOggPackets(status, stream_state, dsp_state)
            if error_status < 0:
                return error_status
            eos = error_status
            error_status = vorbis.vorbis_analysis_blockout(dsp_state, vorbis_block)
        if error_status < 0:
            return error_status
        return eos

    @cython.final
    cdef int _writeOggPackets(self, void* status,
                              ogg.ogg_stream_state* stream_state,
                              vorbis.vorbis_dsp_state* dsp_state) nogil:
        cdef ogg.ogg_packet ogg_packet
        cdef ogg.ogg_page   ogg_page
        cdef int eos, error_status
        eos = 0
        error_status = vorbis.vorbis_bitrate_flushpacket(dsp_state, &ogg_packet)
        while error_status > 0:
            if ogg.ogg_stream_packetin(stream_state, &ogg_packet) < 0:
                return -1
            while ogg.ogg_stream_pageout(stream_state, &ogg_page) != 0 and not eos:
                if self._write(status, &ogg_page) < 0:
                    return -1
                eos = ogg.ogg_page_eos(&ogg_page)
            error_status = vorbis.vorbis_bitrate_flushpacket(dsp_state, &ogg_packet)
        if error_status < 0:
            return error_status
        return eos


cdef class VorbisFileRecoder(_VorbisRecoder):
    cdef object _input_filename

    def __cinit__(self, input_filename):
        self._write = _writeToFile
        self._input_filename = _encodeFilename(input_filename)

    def recode(self, output_filename, int quality):
        cdef vorbis.OggVorbis_File vorbisfile
        cdef stdio.FILE* cinfile
        cdef stdio.FILE* coutfile

        output_filename = _encodeFilename(output_filename)
        cinfile = stdio.fopen(self._input_filename, "r")
        if cinfile is NULL:
            cpython.exc.PyErr_SetFromErrno(IOError)

        result = vorbis.ov_open(cinfile, &vorbisfile, NULL, 0)
        if result == vorbis.OV_ENOTVORBIS:
            stdio.fclose(cinfile)
            raise VorbisException(
                "%r is not a Vorbis file" % self._input_filename)
        if result < 0:
            stdio.fclose(cinfile)
            raise IOError("Error reading from file %r" % self._input_filename)

        coutfile = stdio.fopen(output_filename, "w")
        if coutfile == NULL:
            vorbis.ov_clear(&vorbisfile) # closes the input file
            raise IOError("Error opening output file %r" % output_filename)

        t = 0
        try:
            t = self._recode(coutfile, &vorbisfile, quality)
        finally:
            stdio.fclose(coutfile)
        return t


cdef int _writeToFile(void* coutfile, ogg.ogg_page* ogg_page) nogil:
    cdef size_t count
    count = ogg_page.header_len
    if stdio.fwrite(ogg_page.header, 1, count, <stdio.FILE*>coutfile) < count:
        return -1
    count = ogg_page.body_len
    if stdio.fwrite(ogg_page.body,   1, count, <stdio.FILE*>coutfile) < count:
        return -1
    return 0


@cython.final
cdef class FilelikeReader:
    cdef object read
    cdef object tell
    cdef object seek
    cdef object close
    cdef object exception

    def __cinit__(self, f):
        self.read  = f.read
        self.tell  = f.tell
        self.seek  = f.seek
        try:
            self.close = f.close
        except AttributeError:
            pass

    cdef void _storeException(self, exception):
        if self.exception is None:
            if exception is None:
                self.exception = sys.exc_info()
            else:
                self.exception = exception
    

cdef class VorbisFilelikeRecoder(_VorbisRecoder):
    cdef object f

    def __cinit__(self, f):
        if not hasattr(f, 'read') or \
               not hasattr(f, 'tell') or \
               not hasattr(f, 'seek'):
            raise TypeError, "Seekable file-like object required, got %s" % type(f)
        self.f = f
        self._write = _writeToFilelike

    def recode(self, f, int quality):
        cdef vorbis.OggVorbis_File vorbisfile
        cdef FilelikeReader reader
        write = f.write # make sure it's there
        if not callable(write):
            raise TypeError("writable file-like object required, got %s" % type(f).__name__)
        reader = FilelikeReader(self.f)

        result = vorbis.ov_open_callbacks(<void*>reader, &vorbisfile,
                                          NULL, 0, filelike_callbacks)
        if result == vorbis.OV_ENOTVORBIS:
            raise VorbisException("file is not a Vorbis file")
        elif result < 0:
            raise IOError("Error reading from file-like")

        t = self._recode(<void*>write, &vorbisfile, quality)

        if reader.exception is not None:
            raise reader.exception[0], reader.exception[1], reader.exception[2]

        return t


cdef int _writeToFilelike(void* outfile_write, ogg.ogg_page* ogg_page) with gil:
    try:
        write = <object>outfile_write
        write(ogg_page.header[:ogg_page.header_len])
        write(ogg_page.body[:ogg_page.body_len])
        return 0
    except:
        return -1


cdef size_t _readFilelike(void* dest, size_t size, size_t count,
                          void* creader) with gil:
    cdef FilelikeReader reader = <FilelikeReader>creader
    try:
        data = reader.read(size * count)
        if data is None:
            return 0
        elif isinstance(data, bytes):
            length = len(<bytes>data)
            if length > size * count:
                reader._storeException(
                    ValueError("Returned string is too long"))
            else:
                if length > 0:
                    memcpy(dest, <char*><bytes>data, length)
                return length
        else:
            reader._storeException(
                TypeError(
                    "Invalid return type from read(), bytes required, got %s"
                    % type(data.__name__)))
    except:
        reader._storeException(None)
    errno = -1  # propagate read error
    return 0


cdef int _seekFilelike(void* creader, ogg.ogg_int64_t offset, int whence) with gil:
    cdef FilelikeReader reader = <FilelikeReader>creader
    try:
        reader.seek(offset, whence)
        return 0
    except:
        reader._storeException(None)
    return -1


cdef long _tellFilelike(void* creader) with gil:
    cdef FilelikeReader reader = <FilelikeReader>creader
    try:
        return reader.tell()
    except:
        reader._storeException(None)
    return -1


cdef int _closeFilelike(void* creader) with gil:
    cdef FilelikeReader reader = <FilelikeReader>creader
    try:
        reader.seek(0)
        return 0
    except:
        reader._storeException(None)
    return -1


cdef void _splitStereo(char* decbuffer, float* channel1, float* channel2,
                       int samples) nogil:
    cdef int i
    for i in range(samples):
        channel1[i] = (
            ((decbuffer[i*4+1] << 8) | (0x00ff & <int>decbuffer[i*4]))
            ) / 32768.0

        channel2[i] = (
            ((decbuffer[i*4+3] << 8) | (0x00ff & <int>decbuffer[i*4+2]))
            ) / 32768.0


cdef int _initVorbisEncoder(ogg.ogg_stream_state* stream_state,
                            vorbis.vorbis_dsp_state* dsp_state,
                            vorbis.vorbis_info* vorbis_info,
                            int serialno):
    vorbis.vorbis_analysis_init(dsp_state, vorbis_info)
    return ogg.ogg_stream_init(stream_state, serialno)
