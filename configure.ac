###
###    Copyright (C) 2010 Huseyin Kerem Cevahir <kerem@medra.com.tr>
###
###--------------------------------------------------------------------------
###    This file is part of MyDLP.
###
###    MyDLP is free software: you can redistribute it and/or modify
###    it under the terms of the GNU General Public License as published by
###    the Free Software Foundation, either version 3 of the License, or
###    (at your option) any later version.
###
###    MyDLP is distributed in the hope that it will be useful,
###    but WITHOUT ANY WARRANTY; without even the implied warranty of
###    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
###    GNU General Public License for more details.
###
###    You should have received a copy of the GNU General Public License
###    along with MyDLP.  If not, see <http://www.gnu.org/licenses/>.
###--------------------------------------------------------------------------

AC_INIT([mydlp], [0.6.0.dev], [kerem@mydlp.org])

AC_PREREQ([2.64])
AC_COPYRIGHT([Copyright (C) 2010 Huseyin Kerem Cevahir])
AM_INIT_AUTOMAKE

AC_ERLANG_NEED_ERLC
AC_PREFIX_PROGRAM(erl)
AC_ERLANG_SUBST_ROOT_DIR
AC_ERLANG_SUBST_ERTS_VER
AC_ERLANG_SUBST_LIB_DIR
AC_ERLANG_CHECK_LIB([kernel])
AC_ERLANG_CHECK_LIB([stdlib])
AC_ERLANG_CHECK_LIB([edoc])
AC_ERLANG_CHECK_LIB([eunit])
AC_ERLANG_CHECK_LIB([mnesia])
AC_ERLANG_CHECK_LIB([xmerl])
AC_ERLANG_CHECK_LIB([ssl])
AC_ERLANG_CHECK_LIB([crypto])
AC_ERLANG_CHECK_LIB([sasl])
AC_ERLANG_CHECK_LIB([thrift])
AC_ERLANG_CHECK_LIB([mysql_driver])
AC_ERLANG_CHECK_LIB([bayeserl])
AC_ERLANG_SUBST_INSTALL_LIB_SUBDIR([mydlp], [0.6.0.dev])

AM_PATH_PYTHON

AC_PROG_CC
AC_PROG_CXX
AC_PROG_LIBTOOL

AC_PATH_PROG(THRIFT, thrift, thrift, $PATH:/usr/local/bin:/usr/bin)
AC_PATH_PROG(MVN, mvn, mvn, $PATH:/usr/local/bin:/usr/bin:/opt/maven/bin)
AC_PATH_PROG(WGET, wget, wget, $PATH:/usr/local/bin:/usr/bin:/bin)
AC_PROG_LN_S

AC_CONFIG_FILES([
		Makefile 
		src/Makefile
		src/mydlp/Makefile
		src/mydlp/mydlp.app
		src/mydlp/mydlp.rel
		src/mydlp/overview.edoc
		src/mod_dlp/Makefile
		src/thrift/Makefile
		src/backend/Makefile
		src/backend/py/Makefile
		src/beacon/Makefile
		src/rest/Makefile
	])
AC_OUTPUT
