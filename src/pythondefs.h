#ifndef HAS_PYTHON_DEFS_H
#define HAS_PYTHON_DEFS_H

/* v_arg functions */
#define va_int(ap)     va_arg(ap, int)
#define va_charptr(ap) va_arg(ap, char *)

/* Py_ssize_t support was added in Python 2.5 */
#if PY_VERSION_HEX < 0x02050000
#ifndef PY_SSIZE_T_MAX /* patched Pyrex? */
  typedef int Py_ssize_t;
  #define PY_SSIZE_T_MAX INT_MAX
  #define PY_SSIZE_T_MIN INT_MIN
  #define PyInt_FromSsize_t(z) PyInt_FromLong(z)
  #define PyInt_AsSsize_t(o)   PyInt_AsLong(o)
#endif
#endif

/* Redefinition of some Python builtins as C functions */
#define _cstr(s)        PyString_AS_STRING(s)
#define _isString(obj)   PyObject_TypeCheck(obj, &PyBaseString_Type)

#endif /* HAS_PYTHON_DEFS_H */
