using BinDeps

using Compat
import Compat.Libdl
import Compat.Sys

@eval BinDeps begin

    function _find_library(dep::LibraryDependency; provider = Any)
        ret = Any[]
        # Same as find_library, but with extra check defined by dep
        libnames = [dep.name;get(dep.properties,:aliases,String[])]
        # Make sure we keep the defaults first, but also look in the other directories
        providers = unique([reduce(vcat,[getallproviders(dep,p) for p in defaults]);dep.providers])
        for (p,opts) in providers
            (p !== nothing && can_use(typeof(p)) && can_provide(p,opts,dep)) || continue
            paths = AbstractString[]
    
            # Allow user to override installation path
            if haskey(opts,:installed_libpath) && isdir(opts[:installed_libpath])
                pushfirst!(paths,opts[:installed_libpath])
            end
    
            ppaths = libdir(p,dep)
            append!(paths,isa(ppaths,Array) ? ppaths : [ppaths])
    
            if haskey(opts,:unpacked_dir)
                dir = opts[:unpacked_dir]
                if dir == "." && isdir(joinpath(depsdir(dep), dep.name))
                    # the archive unpacks into the root, so we created a subdir with the dep name
                    push!(paths, joinpath(depsdir(dep), dep.name))
                elseif isdir(joinpath(depsdir(dep),dir))
                    push!(paths,joinpath(depsdir(dep),dir))
                end
            end
    
            # Windows, do you know what `lib` stands for???
            if Compat.Sys.iswindows()
                push!(paths,bindir(p,dep))
            end
            (isempty(paths) || all(map(isempty,paths))) && continue
            for lib in libnames, path in paths
                @info "testing $lib"
                l = joinpath(path, lib)
                @show h = Libdl.dlopen_e(l, Libdl.RTLD_LAZY)
                if h != C_NULL
                    @info "validating $lib"
                    works = dep.libvalidate(l,h)
                    @info "done validating $lib"
                    l = Libdl.dlpath(h)
                    Libdl.dlclose(h)
                    if works
                        push!(ret, ((p, opts), l))
                    else
                        # We tried to load this providers' library, but it didn't satisfy
                        # the requirements, so tell it to force a rebuild since the requirements
                        # have most likely changed
                        opts[:force_rebuild] = true
                    end
                end
                @info "done testing $lib"
            end
        end
        # Now check system libraries
        for lib in libnames
            # We don't want to use regular dlopen, because we want to get at
            # system libraries even if one of our providers is higher in the
            # DL_LOAD_PATH
            for path in Libdl.DL_LOAD_PATH
                for ext in EXTENSIONS
                    opath = string(joinpath(path,lib),ext)
                    check_path!(ret,dep,opath)
                end
            end
            for ext in EXTENSIONS
                opath = string(lib,ext)
                check_path!(ret,dep,opath)
            end
            soname = lookup_soname(lib)
            isempty(soname) || check_path!(ret, dep, soname)
        end
        return ret
    end

end

@BinDeps.setup

# check for cairo version
function validate_cairo_version(name,handle)
    f = Libdl.dlsym_e(handle, "cairo_version")
    f == C_NULL && return false
    v = ccall(f, Int32,())
    return v > 10800
end

group = library_group("cairo")


libpng = library_dependency("png", aliases = ["libpng","libpng-1.5.14","libpng15","libpng12.so.0","libpng12"], runtime = false, group = group)
pixman = library_dependency("pixman", aliases = ["libpixman","libpixman-1","libpixman-1-0","libpixman-1.0"], depends = [libpng], runtime = false, group = group)
libffi = library_dependency("ffi", aliases = ["libffi"], runtime = false, group = group)
gettext = library_dependency("gettext", aliases = ["libintl", "preloadable_libintl", "libgettextpo", "intltool"], os = :Unix, group = group)
gobject = library_dependency("gobject", aliases = ["libgobject-2.0-0", "libgobject-2.0", "libgobject-2_0-0", "libgobject-2.0.so.0"], depends=[libffi, gettext], group = group)
freetype = library_dependency("freetype", aliases = ["libfreetype"], runtime = false, group = group)
fontconfig = library_dependency("fontconfig", aliases = ["libfontconfig-1", "libfontconfig", "libfontconfig.so.1"], depends = [freetype], runtime = false, group = group)
cairo = library_dependency("cairo", aliases = ["libcairo-2", "libcairo","libcairo.so.2", "libcairo2"], depends = [gobject,fontconfig,libpng], group = group, validate = validate_cairo_version)
pango = library_dependency("pango", aliases = ["libpango-1.0-0", "libpango-1.0","libpango-1.0.so.0", "libpango-1_0-0"], group = group)
pangocairo = library_dependency("pangocairo", aliases = ["libpangocairo-1.0-0", "libpangocairo-1.0", "libpangocairo-1.0.so.0"], depends = [cairo], group = group)
zlib = library_dependency("zlib", aliases = ["libzlib","zlib1"], os = :Windows, group = group)

if Sys.iswindows()
    using WinRPM
    provides(WinRPM.RPM,"libpango-1_0-0",[pango,pangocairo],os = :Windows)
    provides(WinRPM.RPM,["glib2", "libgobject-2_0-0"],gobject,os = :Windows)
    provides(WinRPM.RPM,"zlib-devel",zlib,os = :Windows)
    provides(WinRPM.RPM,["libcairo2","libharfbuzz0"],cairo,os = :Windows)
end

if Sys.isapple()
    using Homebrew
    Homebrew.add("graphite2")
    provides( Homebrew.HB, "cairo", cairo, os = :Darwin )
    provides( Homebrew.HB, "pango", [pango, pangocairo], os = :Darwin, onload =
    """
    function __init__()
        ENV["PANGO_SYSCONFDIR"] = joinpath("$(Homebrew.prefix())", "etc")
    end
    """ )
    provides( Homebrew.HB, "fontconfig", fontconfig, os = :Darwin )
    provides( Homebrew.HB, "glib", gobject, os = :Darwin )
    provides( Homebrew.HB, "libpng", libpng, os = :Darwin )
    provides( Homebrew.HB, "gettext", gettext, os = :Darwin )
    provides( Homebrew.HB, "freetype", freetype, os = :Darwin )
    provides( Homebrew.HB, "libffi", libffi, os = :Darwin )
    provides( Homebrew.HB, "pixman", pixman, os = :Darwin )
end

# System Package Managers
provides(AptGet,
    Dict(
        "libcairo2" => cairo,
        "libfontconfig1" => fontconfig,
        "libpango1.0-0" => [pango,pangocairo],
        "libglib2.0-0" => gobject,
        "libpng12-0" => libpng,
        "libpixman-1-0" => pixman,
        "gettext" => gettext
    ))

# TODO: check whether these are accurate
provides(Yum,
    Dict(
        "cairo" => cairo,
        "fontconfig" => fontconfig,
        "pango" => [pango,pangocairo],
        "glib2" => gobject,
        "libpng" => libpng,
        "gettext-libs" => gettext
    ))

provides(Zypper,
    Dict(
        "libcairo2" => cairo,
        "libfontconfig" => fontconfig,
        "libpango-1_0" => [pango,pangocairo],
        "libglib-2_0" => gobject,
        "libpng12" => libpng,
        "libpixman-1" => pixman,
        "gettext" => gettext
    ))

const png_version = "1.5.14"

provides(Sources,
    Dict(
        URI("http://www.cairographics.org/releases/pixman-0.28.2.tar.gz") => pixman,
        URI("http://www.cairographics.org/releases/cairo-1.12.16.tar.xz") => cairo,
        URI("http://download.savannah.gnu.org/releases/freetype/freetype-2.4.11.tar.gz") => freetype,
        URI("http://www.freedesktop.org/software/fontconfig/release/fontconfig-2.10.2.tar.gz") => fontconfig,
        URI("http://ftp.gnu.org/pub/gnu/gettext/gettext-0.18.2.tar.gz") => gettext,
        URI("ftp://ftp.simplesystems.org/pub/libpng/png/src/history/libpng15/libpng-$(png_version).tar.gz") => libpng,
        URI("ftp://sourceware.org/pub/libffi/libffi-3.0.11.tar.gz") => libffi,
        URI("http://ftp.gnome.org/pub/gnome/sources/glib/2.34/glib-2.34.3.tar.xz") => gobject,
        URI("http://ftp.gnome.org/pub/GNOME/sources/pango/1.32/pango-1.32.6.tar.xz") => [pango,pangocairo],
        URI("http://zlib.net/zlib-1.2.7.tar.gz") => zlib
    ))

xx(t...) = (Sys.iswindows() ? t[1] : (Sys.islinux() || length(t) == 2) ? t[2] : t[3])

provides(BuildProcess,
    Dict(
        Autotools(libtarget = "pixman/libpixman-1.la", installed_libname = xx("libpixman-1-0.","libpixman-1.","libpixman-1.0.")*Libdl.dlext) => pixman,
        Autotools(libtarget = xx("objs/.libs/libfreetype.la","libfreetype.la")) => freetype,
        Autotools(libtarget = "src/libfontconfig.la") => fontconfig,
        Autotools(libtarget = "src/libcairo.la", configure_options = append!(append!(
                AbstractString[],
                !Sys.islinux() ? AbstractString["--without-x","--disable-xlib","--disable-xcb"] : AbstractString[]),
                Sys.isapple() ? AbstractString["--enable-quartz","--enable-quartz-font","--enable-quartz-image","--disable-gl"] : AbstractString[])) => cairo,
        Autotools(libtarget = "gettext-tools/gnulib-lib/.libs/libgettextlib.la") => gettext,
        Autotools(libtarget = "libffi.la") => libffi,
        Autotools(libtarget = "gobject/libgobject-2.0.la") => gobject,
        Autotools(libtarget = "pango/libpango-1.0.la") => [pango,pangocairo]
    ))

provides(BuildProcess,Autotools(libtarget = "libpng15.la"),libpng,os = :Unix)


if VERSION < v"1.0.0"
provides(SimpleBuild,
    (@build_steps begin
        GetSources(zlib)
        @build_steps begin
            ChangeDirectory(joinpath(BinDeps.depsdir(zlib),"src","zlib-1.2.7"))
            MakeTargets(["-fwin32/Makefile.gcc"])
            #MakeTargets(["-fwin32/Makefile.gcc","DESTDIR=../../usr/","INCLUDE_PATH=include","LIBRARY_PATH=lib","SHARED_MODE=1","install"])
        end
    end),zlib, os = :Windows)
end

prefix=joinpath(BinDeps.depsdir(libpng),"usr")
uprefix = replace(replace(prefix,"\\" => "/"),"C:/" => "/c/")
pngsrcdir = joinpath(BinDeps.depsdir(libpng),"src","libpng-$png_version")
pngbuilddir = joinpath(BinDeps.depsdir(libpng),"builds","libpng-$png_version")
provides(BuildProcess,
    (@build_steps begin
        GetSources(libpng)
        CreateDirectory(pngbuilddir)
        @build_steps begin
            ChangeDirectory(pngbuilddir)
            FileRule(joinpath(prefix,"lib","libpng15.dll"),@build_steps begin
                `cmake -DCMAKE_INSTALL_PREFIX="$prefix" -G"MSYS Makefiles" $pngsrcdir`
                `make`
                `cp 'libpng*.dll' $prefix/lib`
                `cp 'libpng*.a' $prefix/lib`
                `cp 'libpng*.pc' $prefix/lib/pkgconfig`
                `cp pnglibconf.h $prefix/include`
                `cp $pngsrcdir/png.h $prefix/include`
                `cp $pngsrcdir/pngconf.h $prefix/include`
            end)
        end
    end),libpng, os = :Windows)


#= @BinDeps.install Dict([(:gobject, :_jl_libgobject),
                       (:cairo, :_jl_libcairo),
                       (:pango, :_jl_libpango),
                       (:pangocairo, :_jl_libpangocairo)]) =#

 @BinDeps.install Dict([(:gobject, :_jl_libgobject),
 ]) 
