from libc.stdio cimport FILE
from ogg cimport ogg_packet, ogg_int64_t

cdef extern from "vorbis/codec.h" nogil:
    cdef enum VorbisError:
        OV_FALSE      # -1
        OV_EOF        # -2
        OV_HOLE       # -3
        OV_EREAD      # -128
        OV_EFAULT     # -129
        OV_EIMPL      # -130
        OV_EINVAL     # -131
        OV_ENOTVORBIS # -132
        OV_EBADHEADER # -133
        OV_EVERSION   # -134
        OV_ENOTAUDIO  # -135
        OV_EBADPACKET # -136
        OV_EBADLINK   # -137
        OV_ENOSEEK    # -138

    ctypedef struct vorbis_info:
        int version
        int channels
        long rate
        long bitrate_upper
        long bitrate_nominal
        long bitrate_lower
        long bitrate_window

    ctypedef struct vorbis_comment:
        char **user_comments
        int  *comment_lengths
        int  comments
        char *vendor

    ctypedef struct vorbis_dsp_state:
        pass

    ctypedef struct vorbis_block:
        pass

    cdef void vorbis_info_init(vorbis_info* vi)
    cdef void vorbis_info_clear(vorbis_info* vi)

    cdef int vorbis_analysis_init(vorbis_dsp_state *v, vorbis_info *vi)
    cdef int vorbis_analysis_blockout(vorbis_dsp_state *v,vorbis_block *vb)
    cdef int vorbis_analysis(vorbis_block *vb, ogg_packet *op)
    cdef int vorbis_analysis_wrote(vorbis_dsp_state *v, int vals)
    cdef float** vorbis_analysis_buffer(vorbis_dsp_state *v, int vals)
    cdef int vorbis_analysis_headerout(vorbis_dsp_state *v,
                                       vorbis_comment *vc,
                                       ogg_packet *op,
                                       ogg_packet *op_comm,
                                       ogg_packet *op_code)

    cdef int  vorbis_bitrate_addblock(vorbis_block *vb)
    cdef int vorbis_bitrate_flushpacket(vorbis_dsp_state *vd,
                                        ogg_packet *op)

    cdef int  vorbis_block_init(vorbis_dsp_state *v, vorbis_block *vb)
    cdef int  vorbis_block_clear(vorbis_block *vb)
    cdef void vorbis_dsp_clear(vorbis_dsp_state *v)


cdef extern from "vorbis/vorbisfile.h" nogil:

    ctypedef struct OggVorbis_File:
        long current_serialno
        vorbis_info*    vi
        vorbis_comment* vc

    ctypedef struct ov_callbacks:
        size_t (*read_func)  (void *ptr, size_t size, size_t nmemb, void *datasource)
        int    (*seek_func)  (void *datasource, ogg_int64_t offset, int whence)
        int    (*close_func) (void *datasource)
        long   (*tell_func)  (void *datasource)

    cdef int ov_open(FILE *f, OggVorbis_File *vf, char *initial, long ibytes)
    cdef int ov_test(FILE *f, OggVorbis_File *vf, char *initial, long ibytes)
    cdef int ov_test_open(OggVorbis_File *vf)
    cdef int ov_clear(OggVorbis_File *vf)
    cdef long ov_read(OggVorbis_File *vf, char *buffer, int length,
                      int bigendianp, int word, int signed, int *bitstream)

    cdef int ov_open_callbacks(void* datasource, OggVorbis_File *vf, char *initial,
                               long ibytes, ov_callbacks callbacks)


cdef extern from "vorbis/vorbisenc.h" nogil:
    cdef int vorbis_encode_init_vbr(vorbis_info *vi,
                                    long channels, long rate,
                                    float base_quality)
