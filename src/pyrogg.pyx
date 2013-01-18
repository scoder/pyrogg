cimport python, ogg, vorbis

cimport openmp
from cython cimport parallel

from python cimport _cstr, _isString
from cpython cimport pythread

from libc cimport stdio
from libc.string cimport memcpy

cdef object random
import random

cdef object time
from time import time

cdef object sys
import sys


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


cdef class VorbisFile:
    cdef vorbis.OggVorbis_File _vorbisfile
    cdef object filename

    def __init__(self, filename):
        cdef stdio.FILE* cfile
        cdef int result
        cfile = stdio.fopen(filename, "r")
        if cfile is NULL:
            raise IOError, "Opening file %s failed" % filename
        result = vorbis.ov_test(cfile, &self._vorbisfile, NULL, 0)
        if result == 0:
            result = vorbis.ov_test_open(&self._vorbisfile)
        if result < 0:
            vorbis.ov_clear(&self._vorbisfile) # closes the file
            if result == vorbis.OV_ENOTVORBIS:
                raise VorbisException("'%s' is not a Vorbis file" % filename)
            raise IOError("Error reading from file %s" % filename)
        self.filename = filename

    def __dealloc__(self):
        if self.filename is not None:
            vorbis.ov_clear(&self._vorbisfile) # closes the file


ctypedef void (*page_writer_function)(void*, ogg.ogg_page*) nogil

cdef struct communication:   # thread communication
    int done
    int buffer_part
    int waiting
    long read_status[2]

cdef class _VorbisRecoder:
    cdef page_writer_function _write

    cdef _recode(self, void* status, vorbis.OggVorbis_File* vorbisfile,
                 int target_quality):
        cdef long read_status, values_read, t0
        cdef int buffer_part, current_section, result, eos, thread_id
        cdef float cquality
        cdef char* decbuffer
        cdef float** encbuffer
        cdef ogg.ogg_stream_state stream_state
        cdef vorbis.vorbis_info vorbis_info
        cdef vorbis.vorbis_dsp_state dsp_state
        cdef vorbis.vorbis_block vorbis_block
        cdef communication com   # thread communication

        if target_quality > 10:
            cquality = 1.0
        elif target_quality < -1:
            cquality = -0.1
        else:
            cquality = target_quality / 10.0

        # decoding setup
        decbuffer = <char*> python.PyMem_Malloc(READ_BUFFER_SIZE*2)
        if decbuffer is NULL:
            raise MemoryError()

        # encoding setup
        vorbis.vorbis_info_init(&vorbis_info)
        vorbis.vorbis_encode_init_vbr(&vorbis_info, vorbisfile.vi.channels,
                                      vorbisfile.vi.rate, cquality)
        _initVorbisEncoder(&stream_state, &dsp_state, &vorbis_info,
                           random.randint(0, 2**31))
        vorbis.vorbis_block_init(&dsp_state, &vorbis_block)
        self._writeVorbisHeader(status, &stream_state,
                                &dsp_state, vorbisfile.vc)

        t = time()

        ### copy the data
        com.done = 0
        com.waiting = 0
        com.buffer_part = 0
        com.read_status[0] = vorbis.ov_read(
            vorbisfile, decbuffer, READ_BUFFER_SIZE,
            0, 2, 1, &current_section)

        # synchronisation lock
        lock = pythread.PyThread_allocate_lock()
        pythread.PyThread_acquire_lock(lock, pythread.WAIT_LOCK)

        with nogil, parallel.parallel(num_threads=2):
            thread_id = parallel.threadid()
            with gil:
                assert openmp.omp_get_num_threads() == 2  # won't work otherwise ...
                while not com.done:
                    if thread_id == 0:
                        # reader thread
                        buffer_part = 0 if com.buffer_part else 1
                        with nogil:
                            read_status = vorbis.ov_read(
                                vorbisfile,
                                decbuffer + (READ_BUFFER_SIZE if buffer_part else 0),
                                READ_BUFFER_SIZE,
                                0, 2, 1, &current_section)
                        com.read_status[buffer_part] = read_status
                    else:
                        # writer thread
                        buffer_part = com.buffer_part
                        read_status = com.read_status[buffer_part]
                        with nogil:
                            encbuffer = vorbis.vorbis_analysis_buffer(
                                &dsp_state, READ_BUFFER_SIZE/4)
                            if read_status > 0:
                                values_read = read_status / 4
                                _splitStereo(
                                    decbuffer + (READ_BUFFER_SIZE if buffer_part else 0),
                                    encbuffer, values_read)
                            else:
                                values_read = 0
                            vorbis.vorbis_analysis_wrote(&dsp_state, values_read)

                            eos = self._encodeVorbisBlocks(
                                status, &stream_state, &dsp_state, &vorbis_block)
                        if eos:
                            com.done = 1

                    # synchronise, then switch buffer parts
                    if not com.waiting:
                        # I'm first => wait
                        com.waiting = 1
                        with nogil:
                            pythread.PyThread_acquire_lock(lock, pythread.WAIT_LOCK)
                    else:
                        pythread.PyThread_release_lock(lock)
                        com.waiting = 0
                        com.buffer_part = 0 if com.buffer_part else 1

        pythread.PyThread_free_lock(lock)
        t = time() - t

        ### clean up
        ogg.ogg_stream_clear(&stream_state)
        vorbis.vorbis_block_clear(&vorbis_block)
        vorbis.vorbis_dsp_clear(&dsp_state)
        vorbis.vorbis_info_clear(&vorbis_info)
        python.PyMem_Free(decbuffer)

        vorbis.ov_clear(vorbisfile) # closes the input file

        read_status = com.read_status[com.buffer_part]
        if read_status == vorbis.OV_HOLE or read_status == vorbis.OV_EBADLINK:
            raise VorbisDecodeException("lost sync")

        return t

    cdef void _writeVorbisHeader(self, void* status,
                                 ogg.ogg_stream_state* stream_state,
                                 vorbis.vorbis_dsp_state* dsp_state,
                                 vorbis.vorbis_comment* comment):
        cdef ogg.ogg_packet header
        cdef ogg.ogg_packet header_comm
        cdef ogg.ogg_packet header_code
        cdef ogg.ogg_page   header_page
        cdef int result
        vorbis.vorbis_analysis_headerout(dsp_state, comment,
                                         &header, &header_comm, &header_code)

        ogg.ogg_stream_packetin(stream_state, &header)
        ogg.ogg_stream_packetin(stream_state, &header_comm)
        ogg.ogg_stream_packetin(stream_state, &header_code)

        result = ogg.ogg_stream_flush(stream_state, &header_page)
        while result > 0:
            self._write(status, &header_page)
            result = ogg.ogg_stream_flush(stream_state, &header_page)

    cdef int _encodeVorbisBlocks(self, void* status,
                                 ogg.ogg_stream_state* stream_state,
                                 vorbis.vorbis_dsp_state* dsp_state,
                                 vorbis.vorbis_block* vorbis_block) nogil:
        cdef int eos
        eos = 0
        while vorbis.vorbis_analysis_blockout(dsp_state, vorbis_block) == 1:
            vorbis.vorbis_analysis(vorbis_block, NULL)
            vorbis.vorbis_bitrate_addblock(vorbis_block)
            eos = self._writeOggPackets(status, stream_state, dsp_state)
        return eos

    cdef int _writeOggPackets(self, void* status,
                              ogg.ogg_stream_state* stream_state,
                              vorbis.vorbis_dsp_state* dsp_state) nogil:
        cdef ogg.ogg_packet ogg_packet
        cdef ogg.ogg_page   ogg_page
        cdef int eos
        eos = 0
        while vorbis.vorbis_bitrate_flushpacket(dsp_state, &ogg_packet):
            ogg.ogg_stream_packetin(stream_state, &ogg_packet)
            while ogg.ogg_stream_pageout(stream_state, &ogg_page) != 0 and not eos:
                self._write(status, &ogg_page)
                eos = ogg.ogg_page_eos(&ogg_page)
        return eos


cdef class VorbisFileRecoder(_VorbisRecoder):
    cdef object _input_filename

    def __init__(self, input_filename):
        self._input_filename = input_filename
        self._write = _writeToFile

    def recode(self, output_filename, quality):
        cdef vorbis.OggVorbis_File vorbisfile
        cdef stdio.FILE* cinfile
        cdef stdio.FILE* coutfile

        cinfile = stdio.fopen(self._input_filename, "r")
        if cinfile is NULL:
            python.PyErr_SetFromErrno(IOError)
        result = vorbis.ov_open(cinfile, &vorbisfile, NULL, 0)
        if result == vorbis.OV_ENOTVORBIS:
            stdio.fclose(cinfile)
            raise VorbisException, \
                  "'%s' is not a Vorbis file" % self._input_filename
        if result < 0:
            stdio.fclose(cinfile)
            raise IOError, "Error reading from file " + self._input_filename

        coutfile = stdio.fopen(output_filename, "w")
        if coutfile == NULL:
            vorbis.ov_clear(&vorbisfile) # closes the input file
            raise IOError, "Error opening output file " + output_filename

        t = 0
        try:
            t = self._recode(coutfile, &vorbisfile, quality)
        finally:
            stdio.fclose(coutfile)
        return t

cdef void _writeToFile(void* coutfile, ogg.ogg_page* ogg_page) nogil:
    stdio.fwrite(ogg_page.header, 1, ogg_page.header_len, <stdio.FILE*>coutfile)
    stdio.fwrite(ogg_page.body,   1, ogg_page.body_len,   <stdio.FILE*>coutfile)


cdef class FilelikeReader:
    cdef object read
    cdef object tell
    cdef object seek
    cdef object close
    cdef object exception
    def __init__(self, f):
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

    def __init__(self, f):
        if not hasattr(f, 'read') or \
               not hasattr(f, 'tell') or \
               not hasattr(f, 'seek'):
            raise TypeError, "Seekable file-like object required, got %s" % type(f)
        self.f = f
        self._write = _writeToFilelike

    def recode(self, f, quality):
        cdef vorbis.OggVorbis_File vorbisfile
        cdef FilelikeReader reader
        write = f.write # make sure it's there
        if write is None:
            raise TypeError, "writable file-like object required"
        reader = FilelikeReader(self.f)

        result = vorbis.ov_open_callbacks(<void*>reader, &vorbisfile,
                                          NULL, 0, filelike_callbacks)
        if result == vorbis.OV_ENOTVORBIS:
            raise VorbisException, "file is not a Vorbis file"
        elif result < 0:
            raise IOError, "Error reading from file-like"

        t = self._recode(<void*>write, &vorbisfile, quality)

        if reader.exception is not None:
            raise reader.exception[0], reader.exception[1], reader.exception[2]

        return t


cdef void _writeToFilelike(void* outfile_write, ogg.ogg_page* ogg_page) with gil:
    write = <object>outfile_write
    write(ogg_page.header[:ogg_page.header_len])
    write(ogg_page.body[:ogg_page.body_len])

cdef size_t _readFilelike(void* dest, size_t size, size_t count,
                          void* creader):
    cdef FilelikeReader reader
    reader = <FilelikeReader>creader
    try:
        data = reader.read(size * count)
        if data is None:
            return 0
        elif not python.PyString_Check(data):
            reader._storeException(
                TypeError("Invalid return type, string required"))
        elif python.PyString_GET_SIZE(data) == 0:
            return 0
        elif python.PyString_GET_SIZE(data) > size * count:
            reader._storeException(
                ValueError("Returned string is too long"))
        else:
            memcpy(dest, _cstr(data), python.PyString_GET_SIZE(data))
            return python.PyString_GET_SIZE(data)
    except:
        reader._storeException(None)
    stdio.errno = -1
    return 0

cdef int _seekFilelike(void* creader, ogg.ogg_int64_t offset, int whence):
    cdef FilelikeReader reader
    reader = <FilelikeReader>creader
    try:
        reader.seek(offset, whence)
        return 0
    except:
        reader._storeException(None)
    return -1

cdef long _tellFilelike(void* creader):
    cdef FilelikeReader reader
    reader = <FilelikeReader>creader
    try:
        return reader.tell()
    except:
        reader._storeException(None)
    return -1

cdef int _closeFilelike(void* creader):
    cdef FilelikeReader reader
    reader = <FilelikeReader>creader
    try:
        reader.seek(0)
    except:
        pass
    return 0


cdef void _splitStereo(char* decbuffer, float** encbuffer, int bytes) nogil:
    cdef int i
    for i in range(bytes):
        encbuffer[0][i] = (
            ((decbuffer[i*4+1] << 8) | (0x00ff & <int>decbuffer[i*4]))
            ) / 32768.0

        encbuffer[1][i] = (
            ((decbuffer[i*4+3] << 8) | (0x00ff & <int>decbuffer[i*4+2]))
            ) / 32768.0

cdef void _initVorbisEncoder(ogg.ogg_stream_state* stream_state,
                             vorbis.vorbis_dsp_state* dsp_state,
                             vorbis.vorbis_info* vorbis_info,
                             int serialno):
    vorbis.vorbis_analysis_init(dsp_state, vorbis_info)
    ogg.ogg_stream_init(stream_state, serialno)
