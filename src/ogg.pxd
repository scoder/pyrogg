
cdef extern from "ogg/ogg.h" nogil:
    ctypedef long ogg_int64_t
    
    ctypedef struct oggpack_buffer:
        pass

    ctypedef struct ogg_page:
        char *header
        long header_len
        char *body
        long body_len

    ctypedef struct ogg_packet:
        pass

    ctypedef struct ogg_stream_state:
        pass

    cdef int ogg_stream_init(ogg_stream_state *os, int serialno)
    cdef int ogg_stream_clear(ogg_stream_state *os)
    cdef int ogg_stream_destroy(ogg_stream_state *os)

    cdef int ogg_stream_packetin(ogg_stream_state *os, ogg_packet *op)
    cdef int ogg_stream_pageout(ogg_stream_state *os, ogg_page *og)
    cdef int ogg_stream_flush(ogg_stream_state *os, ogg_page *og)

    cdef int ogg_page_eos(ogg_page *og)
