/**
    This library provides Win32 Registry facilities.

    Copyright: Copyright 2003-2004 by Matthew Wilson and Synesis Software
               Written by Matthew Wilson

    License:

    Author:    Matthew Wilson, Kenji Hara

    Histry:
        Created      15th March 2003,
        Updated      25th April 2004,

    Source:    $(PHOBOSSRC std/windows/_registry.d)
*/
/* /////////////////////////////////////////////////////////////////////////////
 *
 * This software is provided 'as-is', without any express or implied
 * warranty. In no event will the authors be held liable for any damages
 * arising from the use of this software.
 *
 * Permission is granted to anyone to use this software for any purpose,
 * including commercial applications, and to alter it and redistribute it
 * freely, in both source and binary form, subject to the following
 * restrictions:
 *
 * -  The origin of this software must not be misrepresented; you must not
 *    claim that you wrote the original software. If you use this software
 *    in a product, an acknowledgment in the product documentation would be
 *    appreciated but is not required.
 * -  Altered source versions must be plainly marked as such, and must not
 *    be misrepresented as being the original software.
 * -  This notice may not be removed or altered from any source
 *    distribution.
 *
 * ////////////////////////////////////////////////////////////////////////// */
module std.windows.registry;

pragma(lib, "advapi32.lib");

import std.array;
import std.system : Endian, endian;
import std.exception;
import std.c.windows.windows;
import std.windows.syserror;
import std.windows.charset: toMBSz, fromMBSz;
import std.conv;
import std.utf : toUTFz, toUTF16z, toUTF8, toUTF16;
import std.__fileinit : useWfuncs;

//debug = winreg;
debug(winreg) import std.stdio;

private
{
    template SelUni(alias Asym, alias Wsym)
    {
        template SelUni(Char)
        {
            static if (is(Char == char))
            {
                alias Asym SelUni;
            }
            else
            {
                static assert (is(Char == wchar));
                alias Wsym SelUni;
            }
        }
    }

    extern (Windows) int lstrlenA(LPCSTR lpString);
    extern (Windows) int lstrlenW(LPCWSTR lpString);

    void enforceSucc(LONG res, lazy string message, string fn = __FILE__, size_t ln = __LINE__)
    {
        if (res != ERROR_SUCCESS)
            throw new RegistryException(message, res, fn, ln);
    }
}

/* ************* Exceptions *************** */

/**
 */
class Win32Exception : Exception
{
    int error;

    this(string message, string fn = __FILE__, size_t ln = __LINE__, Throwable next = null)
    {
        super(msg, fn, ln, next);
    }

    this(string msg, int errnum, string fn = __FILE__, size_t ln = __LINE__, Throwable next = null)
    {
        super(text(msg, " (", error, ")"), fn, ln, next);
        error = errnum;
    }
}

/**
    Exception class thrown by the std.windows.registry classes.
 */
class RegistryException
    : Win32Exception
{
public:
    /**
        Creates an instance of the exception.

        Params:
            message = The message associated with the exception.
     */
    this(string message, string fn = __FILE__, size_t ln = __LINE__, Throwable next = null)
    {
        super(message, fn, ln, next);
    }

    /**
        Creates an instance of the exception, with the given.

        Params:
            message = The message associated with the exception.
            error = The Win32 error number associated with the exception.
     */
    this(string message, int error, string fn = __FILE__, size_t ln = __LINE__, Throwable next = null)
    {
        super(message, error, fn, ln, next);
    }
}

unittest
{
    // (i) Test that we can throw and catch one by its own type
    string message = "Test 1";
    int    code    = 3;

    auto e = collectException!RegistryException(
        enforce(false, new RegistryException(message, code)));
    assert(e.error == code);
}

/* ************* public enumerations *************** */

/**
    Enumeration of the recognised registry access modes.
 */
enum REGSAM
{
    KEY_QUERY_VALUE         = 0x0001,   /// Permission to query subkey data
    KEY_SET_VALUE           = 0x0002,   /// Permission to set subkey data
    KEY_CREATE_SUB_KEY      = 0x0004,   /// Permission to create subkeys
    KEY_ENUMERATE_SUB_KEYS  = 0x0008,   /// Permission to enumerate subkeys
    KEY_NOTIFY              = 0x0010,   /// Permission for change notification
    KEY_CREATE_LINK         = 0x0020,   /// Permission to create a symbolic link
    KEY_WOW64_32KEY         = 0x0200,   /// Enables a 64- or 32-bit application to open a 32-bit key
    KEY_WOW64_64KEY         = 0x0100,   /// Enables a 64- or 32-bit application to open a 64-bit key
    KEY_WOW64_RES           = 0x0300,   ///
    KEY_READ                = (STANDARD_RIGHTS_READ
                               | KEY_QUERY_VALUE | KEY_ENUMERATE_SUB_KEYS | KEY_NOTIFY)
                              & ~(SYNCHRONIZE),
                                        /// Combines the STANDARD_RIGHTS_READ, KEY_QUERY_VALUE,
                                        /// KEY_ENUMERATE_SUB_KEYS, and KEY_NOTIFY access rights
    KEY_WRITE               = (STANDARD_RIGHTS_WRITE
                               | KEY_SET_VALUE | KEY_CREATE_SUB_KEY)
                              & ~(SYNCHRONIZE),
                                        /// Combines the STANDARD_RIGHTS_WRITE, KEY_SET_VALUE,
                                        /// and KEY_CREATE_SUB_KEY access rights
    KEY_EXECUTE             = KEY_READ & ~(SYNCHRONIZE),
                                        /// Permission for read access
    KEY_ALL_ACCESS          = (STANDARD_RIGHTS_ALL
                               | KEY_QUERY_VALUE | KEY_SET_VALUE | KEY_CREATE_SUB_KEY
                               | KEY_ENUMERATE_SUB_KEYS | KEY_NOTIFY | KEY_CREATE_LINK)
                              & ~(SYNCHRONIZE),
                                        /// Combines the KEY_QUERY_VALUE, KEY_ENUMERATE_SUB_KEYS,
                                        /// KEY_NOTIFY, KEY_CREATE_SUB_KEY, KEY_CREATE_LINK, and
                                        /// KEY_SET_VALUE access rights, plus all the standard
                                        /// access rights except SYNCHRONIZE
}

/**
    Enumeration of the recognised registry value types.
 */
enum REG_VALUE_TYPE : DWORD
{
    REG_UNKNOWN                     =  -1,  ///
    REG_NONE                        =   0,  /// The null value type. (In practise this is treated as a zero-length binary array by the Win32 registry)
    REG_SZ                          =   1,  /// A zero-terminated string
    REG_EXPAND_SZ                   =   2,  /// A zero-terminated string containing expandable environment variable references
    REG_BINARY                      =   3,  /// A binary blob
    REG_DWORD                       =   4,  /// A 32-bit unsigned integer
    REG_DWORD_LITTLE_ENDIAN         =   4,  /// A 32-bit unsigned integer, stored in little-endian byte order
    REG_DWORD_BIG_ENDIAN            =   5,  /// A 32-bit unsigned integer, stored in big-endian byte order
    REG_LINK                        =   6,  /// A registry link
    REG_MULTI_SZ                    =   7,  /// A set of zero-terminated strings
    REG_RESOURCE_LIST               =   8,  /// A hardware resource list
    REG_FULL_RESOURCE_DESCRIPTOR    =   9,  /// A hardware resource descriptor
    REG_RESOURCE_REQUIREMENTS_LIST  =  10,  /// A hardware resource requirements list
    REG_QWORD                       =  11,  /// A 64-bit unsigned integer
    REG_QWORD_LITTLE_ENDIAN         =  11,  /// A 64-bit unsigned integer, stored in little-endian byte order
}


/* ************* private *************** */

private
{
    enum DWORD DELETE                   =   0x00010000L;
    enum DWORD READ_CONTROL             =   0x00020000L;
    enum DWORD WRITE_DAC                =   0x00040000L;
    enum DWORD WRITE_OWNER              =   0x00080000L;
    enum DWORD SYNCHRONIZE              =   0x00100000L;

    enum DWORD STANDARD_RIGHTS_REQUIRED =   0x000F0000L;

    enum DWORD STANDARD_RIGHTS_READ     =   0x00020000L/* READ_CONTROL */;
    enum DWORD STANDARD_RIGHTS_WRITE    =   0x00020000L/* READ_CONTROL */;
    enum DWORD STANDARD_RIGHTS_EXECUTE  =   0x00020000L/* READ_CONTROL */;

    enum DWORD STANDARD_RIGHTS_ALL      =   0x001F0000L;

    enum DWORD SPECIFIC_RIGHTS_ALL      =   0x0000FFFFL;

    enum DWORD REG_CREATED_NEW_KEY      =   0x00000001;
    enum DWORD REG_OPENED_EXISTING_KEY  =   0x00000002;
}

private extern (Windows)
{
    LONG function(in HKEY hkey, in LPCSTR lpSubKey, in REGSAM samDesired, in DWORD reserved) pRegDeleteKeyExA;
    LONG function(in HKEY hkey, in LPCWSTR lpSubKey, in REGSAM samDesired, in DWORD reserved) pRegDeleteKeyExW;
}

shared static this()
{
    // WOW64 is the x86 emulator that allows 32-bit Windows-based applications to run seamlessly on 64-bit Windows
    // IsWow64Process Function - Minimum supported client - Windows Vista, Windows XP with SP2
    alias extern(Windows) BOOL function(HANDLE, PBOOL) fptr_t;
    auto IsWow64Process =
        cast(fptr_t)GetProcAddress(enforce(GetModuleHandleA("kernel32")), "IsWow64Process");
    BOOL bIsWow64;
    isWow64 = IsWow64Process && IsWow64Process(GetCurrentProcess(), &bIsWow64) && bIsWow64;

    advapi32Mutex = new shared(Object)();
}

shared static ~this()
{
    freeAdvapi32();
}

private
{
    immutable bool isWow64;
    shared Object advapi32Mutex;
    shared HMODULE hAdvapi32 = null;

    // Returns samDesired but without WoW64 flags if not in WoW64 mode
    // for compatibility with Windows 2000
    REGSAM compatibleRegsam(in REGSAM samDesired)
    {
        return isWow64 ? samDesired : cast(REGSAM)(samDesired & ~REGSAM.KEY_WOW64_RES);
    }

    ///Returns true, if we are in WoW64 mode and have WoW64 flags
    bool haveWoW64Job(in REGSAM samDesired)
    {
        return isWow64 && (samDesired & REGSAM.KEY_WOW64_RES);
    }
}

// It will free Advapi32.dll, which may be loaded for RegDeleteKeyEx function
void freeAdvapi32()
{
    synchronized (advapi32Mutex)
        if (hAdvapi32)
        {
            pRegDeleteKeyExA = null;
            pRegDeleteKeyExW = null;
            hAdvapi32 = null;
            enforce(FreeLibrary(cast(void*) hAdvapi32), `FreeLibrary(hAdvapi32)`);
        }
}

private REG_VALUE_TYPE _RVT_from_Endian(Endian endian)
{
    final switch (endian)
    {
        case Endian.bigEndian:
            return REG_VALUE_TYPE.REG_DWORD_BIG_ENDIAN;

        case Endian.littleEndian:
            return REG_VALUE_TYPE.REG_DWORD_LITTLE_ENDIAN;
    }
}

/+
private string expand_environment_strings(in string value)
in
{
    assert(value !is null);
}
body
{
    LPCSTR lpSrc       = toMBSz(value);
    DWORD  cchRequired = ExpandEnvironmentStringsA(lpSrc, null, 0);
    char[] newValue    = new char[cchRequired];

    if (!ExpandEnvironmentStringsA(lpSrc, newValue, newValue.length))
        throw new Win32Exception("Failed to expand environment variables");

    return newValue;
}
+/


private LONG regCloseKey(in HKEY hkey)
in
{
    assert(hkey !is null);
}
body
{
    /* No need to attempt to close any of the standard hive keys.
     * Although it's documented that calling RegCloseKey() on any of
     * these hive keys is ignored, we'd rather not trust the Win32
     * API.
     */
    if (cast(uint)hkey & 0x80000000)
    {
        switch (cast(uint)hkey)
        {
            case HKEY_CLASSES_ROOT:
            case HKEY_CURRENT_USER:
            case HKEY_LOCAL_MACHINE:
            case HKEY_USERS:
            case HKEY_PERFORMANCE_DATA:
            case HKEY_PERFORMANCE_TEXT:
            case HKEY_PERFORMANCE_NLSTEXT:
            case HKEY_CURRENT_CONFIG:
            case HKEY_DYN_DATA:
                return ERROR_SUCCESS;
            default:
                /* Do nothing */
                break;
        }
    }

    return RegCloseKey(hkey);
}

private void regFlushKey(in HKEY hkey)
in
{
    assert(hkey !is null);
}
body
{
    immutable res = RegFlushKey(hkey);
    enforceSucc(res, "Key cannot be flushed");
}

private HKEY regCreateKey(in HKEY hkey, in string subKey, in DWORD dwOptions, in REGSAM samDesired,
                          in LPSECURITY_ATTRIBUTES lpsa, out DWORD disposition)
in
{
    assert(hkey !is null);
    assert(subKey !is null);
}
body
{
    HKEY hkeyResult;
    enforceSucc(
        useWfuncs ? RegCreateKeyExW(
                        hkey, toUTF16z(subKey), 0, null, dwOptions,
                        compatibleRegsam(samDesired), cast(LPSECURITY_ATTRIBUTES) lpsa,
                        &hkeyResult, &disposition)
                  : RegCreateKeyExA(
                        hkey, toMBSz(subKey), 0, null, dwOptions,
                        compatibleRegsam(samDesired), cast(LPSECURITY_ATTRIBUTES) lpsa,
                        &hkeyResult, &disposition),
        "Failed to create requested key: \"" ~ subKey ~ "\"");

    return hkeyResult;
}

private void regDeleteKey(in HKEY hkey, in string subKey, in REGSAM samDesired)
in
{
    assert(hkey !is null);
    assert(subKey !is null);
}
body
{
    LONG res;

    if (haveWoW64Job(samDesired))
    {
        if (useWfuncs)
        {
            if (!pRegDeleteKeyExW)
                synchronized (advapi32Mutex)
                {
                    hAdvapi32 = cast(shared) enforce(
                        LoadLibraryW("Advapi32.dll"), `LoadLibraryW("Advapi32.dll")`
                    );

                    pRegDeleteKeyExW = cast(typeof(pRegDeleteKeyExW))enforce(GetProcAddress(
                        cast(void*) hAdvapi32 , "RegDeleteKeyExW"),
                        `GetProcAddress(hAdvapi32 , "RegDeleteKeyExW")`
                    );
                }
            res = pRegDeleteKeyExW(hkey, toUTF16z(subKey), samDesired, 0);
        }
        else
        {
            if (!pRegDeleteKeyExA)
                synchronized (advapi32Mutex)
                {
                    hAdvapi32 = cast(shared) enforce(
                        LoadLibraryA("Advapi32.dll"), `LoadLibraryA("Advapi32.dll")`
                    );

                    pRegDeleteKeyExA = cast(typeof(pRegDeleteKeyExA))enforce(GetProcAddress(
                        cast(void*) hAdvapi32 , "RegDeleteKeyExA"),
                        `GetProcAddress(hAdvapi32 , "RegDeleteKeyExA")`
                    );
                }
            res = pRegDeleteKeyExA(hkey, toMBSz(subKey), samDesired, 0);
        }
    }
    else
    {
        if (useWfuncs)
        {
            res = RegDeleteKeyW(hkey, toUTF16z(subKey));
        }
        else
        {
            res = RegDeleteKeyA(hkey, toMBSz(subKey));
        }
    }
    enforceSucc(res, "Value cannot be deleted: \"" ~ subKey ~ "\"");
}

private void regDeleteValue(in HKEY hkey, in string valueName)
in
{
    assert(hkey !is null);
    assert(valueName !is null);
}
body
{
    enforceSucc(
        useWfuncs ? RegDeleteValueW(hkey, toUTF16z(valueName))
                  : RegDeleteValueA(hkey, toMBSz(valueName)),
        "Value cannot be deleted: \"" ~ valueName ~ "\"");
}

private HKEY regDup(HKEY hkey)
in
{
    assert(hkey !is null);
}
body
{
    /* Can't duplicate standard keys, but don't need to, so can just return */
    if (cast(uint)hkey & 0x80000000)
    {
        switch (cast(uint)hkey)
        {
            case HKEY_CLASSES_ROOT:
            case HKEY_CURRENT_USER:
            case HKEY_LOCAL_MACHINE:
            case HKEY_USERS:
            case HKEY_PERFORMANCE_DATA:
            case HKEY_PERFORMANCE_TEXT:
            case HKEY_PERFORMANCE_NLSTEXT:
            case HKEY_CURRENT_CONFIG:
            case HKEY_DYN_DATA:
                return hkey;
            default:
                /* Do nothing */
                break;
        }
    }

    HKEY hkeyDup;
    immutable res =
        useWfuncs ? RegOpenKeyW(hkey, null, &hkeyDup)
                  : RegOpenKeyA(hkey, null, &hkeyDup);

    debug(winreg)
    {
        if (res != ERROR_SUCCESS)
        {
            writefln("regDup() failed: 0x%08x 0x%08x %d", hkey, hkeyDup, res);
        }

        assert(res == ERROR_SUCCESS);
    }

    return (res == ERROR_SUCCESS) ? hkeyDup : null;
}

private LONG regEnumKeyName(Char)(in HKEY hkey, in DWORD index, ref Char[] name, out DWORD cchName)
in
{
    assert(hkey !is null);
    assert(name !is null);
    assert(name.length > 0);
}
out(res)
{
    assert(res != ERROR_MORE_DATA);
}
body
{
    alias SelUni!(RegEnumKeyExA, RegEnumKeyExW) RegEnumKeyEx;

    // The Registry API lies about the lengths of a very few sub-key lengths
    // so we have to test to see if it whinges about more data, and provide
    // more if it does.
    for (;;)
    {
        cchName = to!DWORD(name.length);
        immutable res = RegEnumKeyEx!Char(hkey, index, name.ptr, &cchName, null, null, null, null);
        if (res != ERROR_MORE_DATA)
            return res;

        // Now need to increase the size of the buffer and try again
        name.length *= 2;
    }

    assert(0);
}


private LONG regEnumValueName(Char)(in HKEY hkey, in DWORD dwIndex, ref Char[] name, out DWORD cchName)
in
{
    assert(hkey !is null);
}
body
{
    alias SelUni!(RegEnumValueA, RegEnumValueW) RegEnumValue;

    for (;;)
    {
        cchName = to!DWORD(name.length);
        immutable res = RegEnumValue!Char(hkey, dwIndex, name.ptr, &cchName, null, null, null, null);
        if (res != ERROR_MORE_DATA)
            return res;

        name.length *= 2;
    }

    assert(0);
}

private LONG regGetNumSubKeys(Char)(in HKEY hkey, out DWORD cSubKeys, out DWORD cchSubKeyMaxLen)
in
{
    assert(hkey !is null);
}
body
{
    static if (is(Char == wchar))
    {
        return RegQueryInfoKeyW(hkey, null, null, null, &cSubKeys,
                                &cchSubKeyMaxLen, null, null, null, null, null, null);
    }
    else
    {
        return RegQueryInfoKeyA(hkey, null, null, null, &cSubKeys,
                                &cchSubKeyMaxLen, null, null, null, null, null, null);
    }
}

private LONG regGetNumValues(Char)(in HKEY hkey, out DWORD cValues, out DWORD cchValueMaxLen)
in
{
    assert(hkey !is null);
}
body
{
    static if (is(Char == wchar))
    {
        return RegQueryInfoKeyW(hkey, null, null, null, null, null, null,
                                &cValues, &cchValueMaxLen, null, null, null);
    }
    else
    {
        return RegQueryInfoKeyA(hkey, null, null, null, null, null, null,
                                &cValues, &cchValueMaxLen, null, null, null);
    }
}

private REG_VALUE_TYPE regGetValueType(in HKEY hkey, in string name)
in
{
    assert(hkey !is null);
}
body
{
    REG_VALUE_TYPE type;
    enforceSucc(
        useWfuncs ? RegQueryValueExW(hkey, toUTF16z(name), null, cast(LPDWORD) &type, null, null)
                  : RegQueryValueExA(hkey, toMBSz(name), null, cast(LPDWORD) &type, null, null),
        "Value cannot be opened: \"" ~ name ~ "\"");

    return type;
}

private HKEY regOpenKey(in HKEY hkey, in string subKey, in REGSAM samDesired)
in
{
    assert(hkey !is null);
    assert(subKey !is null);
}
body
{
    HKEY hkeyResult;
    enforceSucc(
        useWfuncs ? RegOpenKeyExW(hkey, toUTF16z(subKey), 0, compatibleRegsam(samDesired), &hkeyResult)
                  : RegOpenKeyExA(hkey, toMBSz(subKey), 0, compatibleRegsam(samDesired), &hkeyResult),
        "Failed to open requested key: \"" ~ subKey ~ "\"");

    return hkeyResult;
}

private void regQueryValue(in HKEY hkey, string name, out string value, REG_VALUE_TYPE reqType)
in
{
    assert(hkey !is null);
}
body
{
    REG_VALUE_TYPE type;

    // See bugzilla 961 on this
    union U
    {
        uint    dw;
        ulong   qw;
    };
    U u;
    void* data = &u.qw;
    DWORD cbData = u.qw.sizeof;

    LONG queryValue(Char)()
    {
        alias SelUni!(RegQueryValueExA, RegQueryValueExW) RegQueryValueEx;
        alias SelUni!(toMBSz, toUTF16z) toSTRz;

        auto keyname = toSTRz!Char(name);
        LONG res = RegQueryValueEx!Char(hkey, keyname, null, cast(LPDWORD) &type, data, &cbData);
        if (res == ERROR_MORE_DATA)
        {
            data = (new Char[cbData]).ptr;
            res = RegQueryValueEx!Char(hkey, keyname, null, cast(LPDWORD) &type, data, &cbData);
        }
        return res;
    }

    enforceSucc(
        useWfuncs ? queryValue!wchar() : queryValue!char(),
        "Cannot read the requested value");
    enforce(type == reqType,
            new RegistryException("Value type has been changed since the value was acquired"));

    switch (type)
    {
        case REG_VALUE_TYPE.REG_SZ:
        case REG_VALUE_TYPE.REG_EXPAND_SZ:
            if (useWfuncs)
            {
                auto wstr = (cast(immutable(wchar)*)data)[0 .. cbData / wchar.sizeof];
                assert(wstr.length > 0 && wstr[$-1] == '\0');
                if (wstr.length && wstr[$-1] == '\0')
                    wstr.length = wstr.length - 1;
                assert(wstr.length == 0 || wstr[$-1] != '\0');
                value = toUTF8(wstr);
            }
            else
            {
                auto cstr = (cast(immutable(char)*)data)[0 .. cbData];
                assert(cstr.length > 0 && cstr[$-1] == '\0');
                assert(cstr.length == 1 || cstr[$-2] != '\0');
                value = fromMBSz(cstr.ptr);
                if (value.ptr == cast(immutable(char)*)&u.qw)
                    value = value.idup;         // don't point into the stack
            }
            break;

        case REG_VALUE_TYPE.REG_DWORD_LITTLE_ENDIAN:
            version(LittleEndian)
                value = to!string(u.dw);
            else
                value = to!string(core.bitop.bswap(u.dw));
            break;

        case REG_VALUE_TYPE.REG_DWORD_BIG_ENDIAN:
            version(LittleEndian)
                value = to!string(core.bitop.bswap(u.dw));
            else
                value = to!string(u.dw);
            break;

        case REG_VALUE_TYPE.REG_QWORD_LITTLE_ENDIAN:
            value = to!string(u.qw);
            break;

        case REG_VALUE_TYPE.REG_BINARY:
        case REG_VALUE_TYPE.REG_MULTI_SZ:
        default:
            throw new RegistryException("Cannot read the given value as a string");
    }
}

private void regQueryValue(in HKEY hkey, in string name, out string[] value, REG_VALUE_TYPE reqType)
in
{
    assert(hkey !is null);
}
body
{
    REG_VALUE_TYPE type;

    void queryValue(Char)()
    {
        alias SelUni!(RegQueryValueExA, RegQueryValueExW) RegQueryValueEx;
        alias SelUni!(toMBSz, toUTF16z) toSTRz;

        auto keyname = toSTRz!Char(name);
        Char[] data = new Char[256];
        DWORD cbData = data.length / Char.sizeof;
        LONG res = RegQueryValueEx!Char(hkey, keyname, null, cast(LPDWORD) &type, data.ptr, &cbData);
        if (res == ERROR_MORE_DATA)
        {
            data.length = cbData / Char.sizeof;
            res = RegQueryValueEx!Char(hkey, keyname, null, cast(LPDWORD) &type, data.ptr, &cbData);
        }
        else if (res == ERROR_SUCCESS)
        {
            data.length = cbData / Char.sizeof;
        }
        enforceSucc(res, "Cannot read the requested value");
        enforce(type == REG_VALUE_TYPE.REG_MULTI_SZ,
                new RegistryException("Cannot read the given value as a string"));
        enforce(type == reqType,
                new RegistryException("Value type has been changed since the value was acquired"));

        // Remove last two (or one) null terminator
        assert(data.length > 0 && data[$-1] == '\0');
        data.length = data.length - 1;
        if (data.length > 0 && data[$-1] == '\0')
            data.length = data.length - 1;

        auto list = std.array.split(data[], "\0");
        value.length = list.length;
        foreach (i, ref v; value)
        {
            static if (is(Char == wchar))
                v = toUTF8(list[i]);
            else
                v = fromMBSz(cast(immutable(char)*)list[i].ptr); // assume unique
        }
    }

    useWfuncs ? queryValue!wchar() : queryValue!char();
}

private void regQueryValue(in HKEY hkey, in string name, out uint value, REG_VALUE_TYPE reqType)
in
{
    assert(hkey !is null);
}
body
{
    REG_VALUE_TYPE type;

    DWORD cbData = value.sizeof;
    enforceSucc(
        useWfuncs ? RegQueryValueExW(hkey, toUTF16z(name), null, cast(LPDWORD) &type, &value, &cbData)
                  : RegQueryValueExA(hkey, toMBSz(name), null, cast(LPDWORD) &type, &value, &cbData),
        "Cannot read the requested value");
    enforce(type == reqType,
            new RegistryException("Value type has been changed since the value was acquired"));

    switch (type)
    {
        case REG_VALUE_TYPE.REG_DWORD_LITTLE_ENDIAN:
            version(LittleEndian)
                static assert(REG_VALUE_TYPE.REG_DWORD == REG_VALUE_TYPE.REG_DWORD_LITTLE_ENDIAN);
            else
                value = core.bitop.bswap(value);
            break;

        case REG_VALUE_TYPE.REG_DWORD_BIG_ENDIAN:
            version(LittleEndian)
                value = core.bitop.bswap(value);
            else
                static assert(REG_VALUE_TYPE.REG_DWORD == REG_VALUE_TYPE.REG_DWORD_BIG_ENDIAN);
            break;

        default:
            throw new RegistryException("Cannot read the given value as a 32-bit integer");
    }
}

private void regQueryValue(in HKEY hkey, in string name, out ulong value, REG_VALUE_TYPE reqType)
in
{
    assert(hkey !is null);
}
body
{
    REG_VALUE_TYPE type;

    DWORD cbData = value.sizeof;
    enforceSucc(
        useWfuncs ? RegQueryValueExW(hkey, toUTF16z(name), null, cast(LPDWORD) &type, &value, &cbData)
                  : RegQueryValueExA(hkey, toMBSz(name), null, cast(LPDWORD) &type, &value, &cbData),
        "Cannot read the requested value");
    enforce(type == reqType,
            new RegistryException("Value type has been changed since the value was acquired"));

    switch (type)
    {
        case REG_VALUE_TYPE.REG_QWORD_LITTLE_ENDIAN:
            break;

        default:
            throw new RegistryException("Cannot read the given value as a 64-bit integer");
    }
}

private void regQueryValue(in HKEY hkey, in string name, out byte[] value, REG_VALUE_TYPE reqType)
in
{
    assert(hkey !is null);
}
body
{
    REG_VALUE_TYPE type;

    byte[] data = new byte[100];
    DWORD cbData = data.length;
    LONG res;
    if (useWfuncs)
    {
        auto keyname = toUTF16z(name);
        res = RegQueryValueExW(hkey, keyname, null, cast(LPDWORD) &type, data.ptr, &cbData);
        if (res == ERROR_MORE_DATA)
        {
            data.length = cbData;
            res = RegQueryValueExW(hkey, keyname, null, cast(LPDWORD) &type, data.ptr, &cbData);
        }
    }
    else
    {
        auto keyname = toMBSz(name);
        res = RegQueryValueExA(hkey, keyname, null, cast(LPDWORD) &type, data.ptr, &cbData);
        if (res == ERROR_MORE_DATA)
        {
            data.length = cbData;
            res = RegQueryValueExA(hkey, keyname, null, cast(LPDWORD) &type, data.ptr, &cbData);
        }
    }
    enforceSucc(res, "Cannot read the requested value");
    enforce(type == reqType,
            new RegistryException("Value type has been changed since the value was acquired"));

    switch (type)
    {
        case REG_VALUE_TYPE.REG_BINARY:
            data.length = cbData;
            value = data;
            break;

        default:
            throw new RegistryException("Cannot read the given value as a string");
    }
}

private void regSetValue(in HKEY hkey, in string subKey, in REG_VALUE_TYPE type, in LPCVOID lpData, in DWORD cbData)
in
{
    assert(hkey !is null);
}
body
{
    enforceSucc(
        useWfuncs ? RegSetValueExW(hkey, toUTF16z(subKey), 0, type, cast(BYTE*) lpData, cbData)
                  : RegSetValueExA(hkey, toMBSz(subKey), 0, type, cast(BYTE*) lpData, cbData),
        "Value cannot be set: \"" ~ subKey ~ "\"");
}

private void regProcessNthKey(HKEY hkey, scope void delegate(scope LONG delegate(DWORD, out string)) dg)
{
    void impl(Char)()
    {
        DWORD cSubKeys;
        DWORD cchSubKeyMaxLen;

        immutable res = regGetNumSubKeys!Char(hkey, cSubKeys, cchSubKeyMaxLen);
        assert(res == ERROR_SUCCESS);

        Char[] sName = new Char[cchSubKeyMaxLen + 1];

        dg((DWORD index, out string name)
        {
            DWORD cchName;
            immutable res = regEnumKeyName!Char(hkey, index, sName, cchName);
            if (res == ERROR_SUCCESS)
            {
                static if (is(Char == wchar))
                    name = toUTF8(sName[0 .. cchName]);
                else
                    name = fromMBSz(cast(immutable(char)*) sName.ptr);
            }
            return res;
        });
    }

    useWfuncs ? impl!wchar() : impl!char();
}

private void regProcessNthValue(HKEY hkey, scope void delegate(scope LONG delegate(DWORD, out string)) dg)
{
    void impl(Char)()
    {
        DWORD cValues;
        DWORD cchValueMaxLen;

        immutable res = regGetNumValues!Char(hkey, cValues, cchValueMaxLen);
        assert(res == ERROR_SUCCESS);

        Char[] sName = new Char[cchValueMaxLen + 1];

        dg((DWORD index, out string name)
        {
            DWORD cchName;
            immutable res = regEnumValueName!Char(hkey, index, sName, cchName);
            if (res == ERROR_SUCCESS)
            {
                static if (is(Char == wchar))
                    name = toUTF8(sName[0 .. cchName]);
                else
                    name = fromMBSz(cast(immutable(char)*) sName.ptr);
            }
            return res;
        });
    }

    useWfuncs ? impl!wchar() : impl!char();
}

/* ************* public classes *************** */

/**
    This class represents a registry key.
 */
class Key
{
    invariant()
    {
        assert(m_hkey !is null);
    }

private:
    this(HKEY hkey, string name, bool created)
    in
    {
        assert(hkey !is null);
    }
    body
    {
        m_hkey = hkey;
        m_name = name;
    }

    ~this()
    {
        regCloseKey(m_hkey);

        // Even though this is horried waste-of-cycles programming
        // we're doing it here so that the
        m_hkey = null;
    }

public:
    /// The name of the key
    @property string name() @safe pure nothrow const
    {
        return m_name;
    }

    /**
        The number of sub keys.
     */
    @property size_t keyCount() const
    {
        uint cSubKeys;
        uint cchSubKeyMaxLen;
        enforceSucc(
            useWfuncs ? regGetNumSubKeys!wchar(m_hkey, cSubKeys, cchSubKeyMaxLen)
                      : regGetNumSubKeys!char(m_hkey, cSubKeys, cchSubKeyMaxLen),
            "Number of sub-keys cannot be determined");

        return cSubKeys;
    }

    /**
        An enumerable sequence of all the sub-keys of this key.
     */
    @property KeySequence keys() @safe pure
    {
        return new KeySequence(this);
    }

    /**
        An enumerable sequence of the names of all the sub-keys of this key.
     */
    @property KeyNameSequence keyNames() @safe pure
    {
        return new KeyNameSequence(this);
    }

    /**
        The number of values.
     */
    @property size_t valueCount() const
    {
        uint cValues;
        uint cchValueMaxLen;
        enforceSucc(
            useWfuncs ? regGetNumValues!wchar(m_hkey, cValues, cchValueMaxLen)
                      : regGetNumValues!char(m_hkey, cValues, cchValueMaxLen),
            "Number of values cannot be determined");

        return cValues;
    }

    /**
        An enumerable sequence of all the values of this key.
     */
    @property ValueSequence values() @safe pure
    {
        return new ValueSequence(this);
    }

    /**
        An enumerable sequence of the names of all the values of this key.
     */
    @property ValueNameSequence valueNames() @safe pure
    {
        return new ValueNameSequence(this);
    }

public:
    /**
        Returns the named sub-key of this key.

        Params:
            name = The name of the subkey to create. May not be $(D null).
        Returns:
            The created key.
        Throws:
            $(D RegistryException) is thrown if the key cannot be created.
     */
    Key createKey(string name, REGSAM access = REGSAM.KEY_ALL_ACCESS)
    {
        enforce(!name.empty, new RegistryException("Key name is invalid"));

        DWORD disposition;
        HKEY hkey = regCreateKey(m_hkey, name, 0, access, null, disposition);
        assert(hkey !is null);

        // Potential resource leak here!!
        //
        // If the allocation of the memory for Key fails, the HKEY could be
        // lost. Hence, we catch such a failure by the finally, and release
        // the HKEY there. If the creation of
        try
        {
            Key key = new Key(hkey, name, disposition == REG_CREATED_NEW_KEY);
            hkey = null;
            return key;
        }
        finally
        {
            if (hkey !is null)
            {
                regCloseKey(hkey);
            }
        }
    }

    /**
        Returns the named sub-key of this key.

        Params:
            name = The name of the subkey to aquire. If name is the empty
                   string, then the called key is duplicated.
            access = The desired access; one of the $(D REGSAM) enumeration.
        Returns:
            The aquired key.
        Throws:
            This function never returns $(D null). If a key corresponding to
            the requested name is not found, $(D RegistryException) is thrown.
     */
    Key getKey(string name, REGSAM access = REGSAM.KEY_READ)
    {
        if (name.empty)
            return new Key(regDup(m_hkey), m_name, false);

        HKEY hkey = regOpenKey(m_hkey, name, access);
        assert(hkey !is null);

        // Potential resource leak here!!
        //
        // If the allocation of the memory for Key fails, the HKEY could be
        // lost. Hence, we catch such a failure by the finally, and release
        // the HKEY there. If the creation of
        try
        {
            Key key = new Key(hkey, name, false);
            hkey = null;
            return key;
        }
        finally
        {
            if (hkey != null)
            {
                regCloseKey(hkey);
            }
        }
    }

    /**
        Deletes the named key.

        Params:
            name = The name of the key to delete. May not be $(D null).
     */
    void deleteKey(string name, REGSAM access = cast(REGSAM)0)
    {
        enforce(!name.empty, new RegistryException("Key name is invalid"));

        regDeleteKey(m_hkey, name, access);
    }

    /**
        Returns the named value.
        If $(D name) is the empty string, then the default value is returned.

        Returns:
            This function never returns $(D null). If a value corresponding
            to the requested name is not found, $(D RegistryException) is thrown.
     */
    Value getValue(string name)
    {
        return new Value(this, name, regGetValueType(m_hkey, name));
    }

    /**
        Sets the named value with the given 32-bit unsigned integer value.

        Params:
            name = The name of the value to set. If it is the empty string,
                   sets the default value.
            value = The 32-bit unsigned value to set.
        Throws:
            If a value corresponding to the requested name is not found,
            $(D RegistryException) is thrown.
     */
    void setValue(string name, uint value)
    {
        setValue(name, value, endian);
    }

    /**
        Sets the named value with the given 32-bit unsigned integer value,
        according to the desired byte-ordering.

        Params:
            name = The name of the value to set. If it is the empty string,
                   sets the default value.
            value = The 32-bit unsigned value to set.
            endian = Can be $(D Endian.BigEndian) or $(D Endian.LittleEndian).
        Throws:
            If a value corresponding to the requested name is not found,
            $(D RegistryException) is thrown.
     */
    void setValue(string name, uint value, Endian endian)
    {
        REG_VALUE_TYPE  type = _RVT_from_Endian(endian);

        assert(type == REG_VALUE_TYPE.REG_DWORD_BIG_ENDIAN ||
               type == REG_VALUE_TYPE.REG_DWORD_LITTLE_ENDIAN);

        regSetValue(m_hkey, name, type, &value, value.sizeof);
    }

    /**
        Sets the named value with the given 64-bit unsigned integer value.

        Params:
            name = The name of the value to set. If it is the empty string,
                   sets the default value.
            value = The 64-bit unsigned value to set.
        Throws:
            If a value corresponding to the requested name is not found,
            $(D RegistryException) is thrown.
     */
    void setValue(string name, ulong value)
    {
        regSetValue(m_hkey, name, REG_VALUE_TYPE.REG_QWORD, &value, value.sizeof);
    }

    /**
        Sets the named value with the given string value.

        Params:
            name = The name of the value to set. If it is the empty string,
                   sets the default value.
            value = The string value to set.
        Throws:
            If a value corresponding to the requested name is not found,
            $(D RegistryException) is thrown.
     */
    void setValue(string name, string value)
    {
        setValue(name, value, false);
    }

    /**
        Sets the named value with the given string value.

        Params:
            name = The name of the value to set. If it is the empty string,
                   sets the default value.
            value = The string value to set.
            asEXPAND_SZ = If $(D true), the value will be stored as an
                          expandable environment string, otherwise as a normal string.
        Throws:
            If a value corresponding to the requested name is not found,
            $(D RegistryException) is thrown.
     */
    void setValue(string name, string value, bool asEXPAND_SZ)
    {
        const(void)* data;
        DWORD len;
        if (useWfuncs)
        {
            auto psz = toUTF16z(value);
            data = psz;
            len = lstrlenW(psz) * wchar.sizeof;
        }
        else
        {
            auto psz = toMBSz(value);
            data = psz;
            len = lstrlenA(psz);
        }

        regSetValue(m_hkey, name,
                    asEXPAND_SZ ? REG_VALUE_TYPE.REG_EXPAND_SZ
                                : REG_VALUE_TYPE.REG_SZ,
                    data, len);
    }

    /**
        Sets the named value with the given multiple-strings value.

        Params:
            name = The name of the value to set. If it is the empty string,
                   sets the default value.
            value = The multiple-strings value to set.
        Throws:
            If a value corresponding to the requested name is not found,
            $(D RegistryException) is thrown.
     */
    void setValue(string name, string[] value)
    {
        wstring[] data = new wstring[value.length+1];
        foreach (i, ref s; data[0..$-1])
        {
            s = toUTF16(value[i]);
        }
        data[$-1] = "\0";
        auto ws = std.array.join(data, "\0"w);

        if (useWfuncs)
        {
            regSetValue(m_hkey, name, REG_VALUE_TYPE.REG_MULTI_SZ, ws.ptr, ws.length * wchar.sizeof);
        }
        else
        {
            char[] cs;
            int readLen;
            cs.length = WideCharToMultiByte(/*CP_ACP*/ 0, 0, ws.ptr, ws.length, null, 0, null, null);
            if (cs.length)
            {
                readLen = WideCharToMultiByte(/*CP_ACP*/ 0, 0, ws.ptr, ws.length, cs.ptr, cs.length, null, null);
            }
            enforce(readLen && readLen == cs.length,
                new Win32Exception("Couldn't convert string: " ~ sysErrorString(GetLastError())));

            regSetValue(m_hkey, name, REG_VALUE_TYPE.REG_MULTI_SZ, cs.ptr, cs.length);
        }
    }

    /**
        Sets the named value with the given binary value.

        Params:
            name = The name of the value to set. If it is the empty string,
                   sets the default value.
            value = The binary value to set.
        Throws:
            If a value corresponding to the requested name is not found,
            $(D RegistryException) is thrown.
     */
    void setValue(string name, byte[] value)
    {
        regSetValue(m_hkey, name, REG_VALUE_TYPE.REG_BINARY, value.ptr, to!DWORD(value.length));
    }

    /**
        Deletes the named value.

        Params:
            name = The name of the value to delete. May not be $(D null).
        Throws:
            If a value of the requested name is not found,
            $(D RegistryException) is thrown.
     */
    void deleteValue(string name)
    {
        regDeleteValue(m_hkey, name);
    }

    /**
        Flushes any changes to the key to disk.
     */
    void flush()
    {
        regFlushKey(m_hkey);
    }

private:
    HKEY   m_hkey;
    string m_name;
}

/**
    This class represents a value of a registry key.
 */
class Value
{
    invariant()
    {
        assert(m_key !is null);
    }

private:
    this(Key key, string name, REG_VALUE_TYPE type)
    in
    {
        assert(null !is key);
    }
    body
    {
        m_key = key;
        m_type = type;
        m_name = name;
    }

public:
    /**
        The name of the value.
        If the value represents a default value of a key, which has no name,
        the returned string will be of zero length.
     */
    @property string name() @safe pure nothrow const
    {
        return m_name;
    }

    /**
        The type of value.
     */
    @property REG_VALUE_TYPE type() @safe pure nothrow const
    {
        return m_type;
    }

    /**
        Obtains the current value of the value as a string.
        If the value's type is REG_EXPAND_SZ the returned value is <b>not</b>
        expanded; $(D value_EXPAND_SZ) should be called

        Returns:
            The contents of the value.
        Throws:
            $(D RegistryException) if the type of the value is not REG_SZ,
            REG_EXPAND_SZ, REG_DWORD, or REG_QWORD.
     */
    @property string value_SZ() const
    {
        string value;

        regQueryValue(m_key.m_hkey, m_name, value, m_type);

        return value;
    }

    /**
        Obtains the current value as a string, within which any environment
        variables have undergone expansion.
        This function works with the same value-types as $(D value_SZ).

        Returns:
            The contents of the value.
     */
    @property string value_EXPAND_SZ() const
    {
        string  value   =   value_SZ;

        // value = expand_environment_strings(value);
        // return value;

        // ExpandEnvironemntStrings():
        //      http://msdn2.microsoft.com/en-us/library/ms724265.aspx
        LPCSTR  lpSrc       =   toMBSz(value);
        DWORD   cchRequired =   ExpandEnvironmentStringsA(lpSrc, null, 0);
        char[]  newValue    =   new char[cchRequired];

        if (!ExpandEnvironmentStringsA(lpSrc, newValue.ptr, to!DWORD(newValue.length)))
            throw new Win32Exception("Failed to expand environment variables");

        return fromMBSz(cast(immutable(char)*) newValue.ptr); // remove trailing 0
    }

    /**
        Obtains the current value as an array of strings.

        Returns:
            The contents of the value.
        Throws:
            $(D RegistryException) if the type of the value is not REG_MULTI_SZ.
     */
    @property string[] value_MULTI_SZ() const
    {
        string[] value;

        regQueryValue(m_key.m_hkey, m_name, value, m_type);

        return value;
    }

    /**
        Obtains the current value as a 32-bit unsigned integer, ordered
        correctly according to the current architecture.

        Returns:
            The contents of the value.
        Throws:
            $(D RegistryException) is thrown for all types other than
            REG_DWORD, REG_DWORD_LITTLE_ENDIAN and REG_DWORD_BIG_ENDIAN.
     */
    @property uint value_DWORD() const
    {
        uint value;

        regQueryValue(m_key.m_hkey, m_name, value, m_type);

        return value;
    }

    deprecated uint value_DWORD_LITTLEENDIAN()
    {
        return value_DWORD;
    }

    deprecated uint value_DWORD_BIGENDIAN()
    {
        return value_DWORD;
    }

    /**
        Obtains the value as a 64-bit unsigned integer, ordered correctly
        according to the current architecture.

        Returns:
            The contents of the value.
        Throws:
            $(D RegistryException) if the type of the value is not REG_QWORD.
     */
    @property ulong value_QWORD() const
    {
        ulong value;

        regQueryValue(m_key.m_hkey, m_name, value, m_type);

        return value;
    }

    deprecated ulong value_QWORD_LITTLEENDIAN()
    {
        return value_QWORD;
    }

    /**
        Obtains the value as a binary blob.

        Returns:
            The contents of the value.
        Throws:
            $(D RegistryException) if the type of the value is not REG_BINARY.
     */
    @property byte[] value_BINARY() const
    {
        byte[] value;

        regQueryValue(m_key.m_hkey, m_name, value, m_type);

        return value;
    }

private:
    Key             m_key;
    REG_VALUE_TYPE  m_type;
    string          m_name;
}

/**
    Represents the local system registry.
 */
abstract final class Registry
{
private:
    shared static this()
    {
        sm_keyClassesRoot     = new Key(regDup(HKEY_CLASSES_ROOT),     "HKEY_CLASSES_ROOT",     false);
        sm_keyCurrentUser     = new Key(regDup(HKEY_CURRENT_USER),     "HKEY_CURRENT_USER",     false);
        sm_keyLocalMachine    = new Key(regDup(HKEY_LOCAL_MACHINE),    "HKEY_LOCAL_MACHINE",    false);
        sm_keyUsers           = new Key(regDup(HKEY_USERS),            "HKEY_USERS",            false);
        sm_keyPerformanceData = new Key(regDup(HKEY_PERFORMANCE_DATA), "HKEY_PERFORMANCE_DATA", false);
        sm_keyCurrentConfig   = new Key(regDup(HKEY_CURRENT_CONFIG),   "HKEY_CURRENT_CONFIG",   false);
        sm_keyDynData         = new Key(regDup(HKEY_DYN_DATA),         "HKEY_DYN_DATA",         false);
    }

public:
    /// Returns the root key for the HKEY_CLASSES_ROOT hive
    static @property Key classesRoot()     { return sm_keyClassesRoot; }
    /// Returns the root key for the HKEY_CURRENT_USER hive
    static @property Key currentUser()     { return sm_keyCurrentUser; }
    /// Returns the root key for the HKEY_LOCAL_MACHINE hive
    static @property Key localMachine()    { return sm_keyLocalMachine; }
    /// Returns the root key for the HKEY_USERS hive
    static @property Key users()           { return sm_keyUsers; }
    /// Returns the root key for the HKEY_PERFORMANCE_DATA hive
    static @property Key performanceData() { return sm_keyPerformanceData; }
    /// Returns the root key for the HKEY_CURRENT_CONFIG hive
    static @property Key currentConfig()   { return sm_keyCurrentConfig; }
    /// Returns the root key for the HKEY_DYN_DATA hive
    static @property Key dynData()         { return sm_keyDynData; }

private:
    __gshared Key  sm_keyClassesRoot;
    __gshared Key  sm_keyCurrentUser;
    __gshared Key  sm_keyLocalMachine;
    __gshared Key  sm_keyUsers;
    __gshared Key  sm_keyPerformanceData;
    __gshared Key  sm_keyCurrentConfig;
    __gshared Key  sm_keyDynData;
}

/**
    An enumerable sequence representing the names of the sub-keys of a registry Key.

Example:
----
Key key = ...
foreach (string subkeyName; key.keyNames)
{
    // using subkeyName
}
----
 */
class KeyNameSequence
{
    invariant()
    {
        assert(m_key !is null);
    }

private:
    this(Key key)
    {
        m_key = key;
    }

public:
    /**
        The number of keys.
     */
    @property size_t count() const
    {
        return m_key.keyCount;
    }

    /**
        The name of the key at the given index.

        Params:
            index = The 0-based index of the key to retrieve.
        Returns:
            The name of the key corresponding to the given index.
        Throws:
            RegistryException if no corresponding key is retrieved.
     */
    string getKeyName(size_t index)
    {
        string name;
        regProcessNthKey(m_key.m_hkey, (scope LONG delegate(DWORD, out string) getName)
        {
            enforceSucc(getName(to!DWORD(index), name), "Invalid key");
        });
        return name;
    }

    /**
        The name of the key at the given index.

        Params:
            index = The 0-based index of the key to retrieve.
        Returns:
            The name of the key corresponding to the given index.
        Throws:
            $(D RegistryException) if no corresponding key is retrieved.
     */
    string opIndex(size_t index)
    {
        return getKeyName(index);
    }

public:
    ///
    int opApply(scope int delegate(ref string name) dg)
    {
        int result;
        regProcessNthKey(m_key.m_hkey, (scope LONG delegate(DWORD, out string) getName)
        {
            for (DWORD index = 0; !result; ++index)
            {
                string name;
                immutable res = getName(index, name);
                if (res == ERROR_NO_MORE_ITEMS) // Enumeration complete
                    break;
                enforceSucc(res, "Key name enumeration incomplete");

                result = dg(name);
            }
        });
        return result;
    }

private:
    Key m_key;
}


/**
    An enumerable sequence representing the sub-keys of a registry Key.

Example:
----
Key key = ...
foreach (Key subkey; key.keys)
{
    // using subkey
}
----
 */
class KeySequence
{
    invariant()
    {
        assert(m_key !is null);
    }

private:
    this(Key key)
    {
        m_key = key;
    }

public:
    /**
        The number of keys.
     */
    @property size_t count() const
    {
        return m_key.keyCount;
    }

    /**
        The key at the given index.

        Params:
            index = The 0-based index of the key to retrieve.
        Returns:
            The key corresponding to the given index.
        Throws:
            $(D RegistryException) if no corresponding key is retrieved.
     */
    Key getKey(size_t index)
    {
        string name;
        regProcessNthKey(m_key.m_hkey, (scope LONG delegate(DWORD, out string) getName)
        {
            enforceSucc(getName(to!DWORD(index), name), "Invalid key");
        });
        return m_key.getKey(name);
    }

    /**
        The key at the given index.

        Params:
            index = The 0-based index of the key to retrieve.
        Returns:
            The key corresponding to the given index.
        Throws:
            $(D RegistryException) if no corresponding key is retrieved.
     */
    Key opIndex(size_t index)
    {
        return getKey(index);
    }

public:
    ///
    int opApply(scope int delegate(ref Key key) dg)
    {
        int result = 0;
        regProcessNthKey(m_key.m_hkey, (scope LONG delegate(DWORD, out string) getName)
        {
            for (DWORD index = 0; !result; ++index)
            {
                string name;
                immutable res = getName(index, name);
                if (res == ERROR_NO_MORE_ITEMS) // Enumeration complete
                    break;
                enforceSucc(res, "Key enumeration incomplete");

                try
                {
                    Key key = m_key.getKey(name);
                    result = dg(key);
                }
                catch (RegistryException e)
                {
                    // Skip inaccessible keys; they are
                    // accessible via the KeyNameSequence
                    if (e.error == ERROR_ACCESS_DENIED)
                        continue;

                    throw e;
                }
            }
        });
        return result;
    }

private:
    Key m_key;
}

/**
    An enumerable sequence representing the names of the values of a registry Key.

Example:
----
Key key = ...
foreach (string valueName; key.valueNames)
{
    // using valueName
}
----
 */
class ValueNameSequence
{
    invariant()
    {
        assert(m_key !is null);
    }

private:
    this(Key key)
    {
        m_key = key;
    }

public:
    /**
        The number of values.
     */
    @property size_t count() const
    {
        return m_key.valueCount;
    }

    /**
        The name of the value at the given index.

        Params:
            index = The 0-based index of the value to retrieve.
        Returns:
            The name of the value corresponding to the given index.
        Throws:
            $(D RegistryException) if no corresponding value is retrieved.
     */
    string getValueName(size_t index)
    {
        string name;
        regProcessNthValue(m_key.m_hkey, (scope LONG delegate(DWORD, out string) getName)
        {
            enforceSucc(getName(to!DWORD(index), name), "Invalid value");
        });
        return name;
    }

    /**
        The name of the value at the given index.

        Params:
            index = The 0-based index of the value to retrieve.
        Returns:
            The name of the value corresponding to the given index.
        Throws:
            $(D RegistryException) if no corresponding value is retrieved.
     */
    string opIndex(size_t index)
    {
        return getValueName(index);
    }

public:
    ///
    int opApply(scope int delegate(ref string name) dg)
    {
        int result = 0;
        regProcessNthValue(m_key.m_hkey, (scope LONG delegate(DWORD, out string) getName)
        {
            for (DWORD index = 0; !result; ++index)
            {
                string name;
                immutable res = getName(index, name);
                if (res == ERROR_NO_MORE_ITEMS) // Enumeration complete
                    break;
                enforceSucc(res, "Value name enumeration incomplete");

                result = dg(name);
            }
        });
        return result;
    }

private:
    Key m_key;
}

/**
    An enumerable sequence representing the values of a registry Key.

Example:
----
Key key = ...
foreach (Value value; key.values)
{
    // using value
}
----
 */
class ValueSequence
{
    invariant()
    {
        assert(m_key !is null);
    }

private:
    this(Key key)
    {
        m_key = key;
    }

public:
    /// The number of values
    @property size_t count() const
    {
        return m_key.valueCount;
    }

    /**
        The value at the given $(D index).

        Params:
            index = The 0-based index of the value to retrieve
        Returns:
            The value corresponding to the given index.
        Throws:
            $(D RegistryException) if no corresponding value is retrieved
     */
    Value getValue(size_t index)
    {
        string name;
        regProcessNthValue(m_key.m_hkey, (scope LONG delegate(DWORD, out string) getName)
        {
            enforceSucc(getName(to!DWORD(index), name), "Invalid value");
        });
        return m_key.getValue(name);
    }

    /**
        The value at the given $(D index).

        Params:
            index = The 0-based index of the value to retrieve.
        Returns:
            The value corresponding to the given index.
        Throws:
            $(D RegistryException) if no corresponding value is retrieved.
     */
    Value opIndex(size_t index)
    {
        return getValue(index);
    }

public:
    ///
    int opApply(scope int delegate(ref Value value) dg)
    {
        int result = 0;
        regProcessNthValue(m_key.m_hkey, (scope LONG delegate(DWORD, out string) getName)
        {
            for (DWORD index = 0; !result; ++index)
            {
                string name;
                immutable res = getName(index, name);
                if (res == ERROR_NO_MORE_ITEMS) // Enumeration complete
                    break;
                enforceSucc(res, "Value enumeration incomplete");

                Value value = m_key.getValue(name);
                result = dg(value);
            }
        });
        return result;
    }

private:
    Key m_key;
}


unittest
{
    debug(winreg) scope(success) writeln("unittest @", __FILE__, ":", __LINE__, " succeeded.");
    debug(winreg) writefln("std.windows.registry.unittest read");

    auto save_useWfuncs = useWfuncs;
    scope(exit) useWfuncs = save_useWfuncs;

    foreach (loop; 0..2)
    {
        if (loop == 0) useWfuncs = false;
        else           useWfuncs = true;

/+
        // Mask for test speed up

        Key HKCR  = Registry.classesRoot;
        Key CLSID = HKCR.getKey("CLSID");

        foreach (Key key; CLSID.keys)
        {
            foreach (Value val; key.values)
            {
            }
        }
+/
        Key HKCU = Registry.currentUser;
        assert(HKCU);

        // Enumerate all subkeys of key Software
        Key softwareKey = HKCU.getKey("Software");
        assert(softwareKey);
        foreach (Key key; softwareKey.keys)
        {
            //writefln("Key %s", key.name);
            foreach (Value val; key.values)
            {
            }
        }
    }
}

unittest
{
    debug(winreg) scope(success) writeln("unittest @", __FILE__, ":", __LINE__, " succeeded.");
    debug(winreg) writefln("std.windows.registry.unittest write");

    auto save_useWfuncs = useWfuncs;
    scope(exit) useWfuncs = save_useWfuncs;

    foreach (loop; 0..2)
    {
        if (loop == 0) useWfuncs = false;
        else           useWfuncs = true;

        if (useWfuncs == false)
            continue;

        // Warning: This unit test writes to the registry.
        // The test can fail if you don't have sufficient rights

        Key HKCU = Registry.currentUser;
        assert(HKCU);

        // Create a new key
        string unittestKeyName = "Temporary key for a D UnitTest which can be deleted afterwards";
        Key unittestKey = HKCU.createKey(unittestKeyName);
        assert(unittestKey);
        Key cityKey = unittestKey.createKey("CityCollection using foreign names with umlauts and accents: \u00f6\u00e4\u00fc\u00d6\u00c4\u00dc\u00e0\u00e1\u00e2\u00df");
        cityKey.setValue("K\u00f6ln", "Germany"); // Cologne
        cityKey.setValue("\u041c\u0438\u043d\u0441\u043a", "Belarus"); // Minsk
        cityKey.setValue("\u5317\u4eac", "China"); // Bejing
        bool foundCologne, foundMinsk, foundBeijing;
        foreach (Value v; cityKey.values)
        {
            auto vname = v.name;
            auto vvalue_SZ = v.value_SZ;
            if (v.name == "K\u00f6ln")
            {
                foundCologne = true;
                assert(v.value_SZ == "Germany");
            }
            if (v.name == "\u041c\u0438\u043d\u0441\u043a")
            {
                foundMinsk = true;
                assert(v.value_SZ == "Belarus");
            }
            if (v.name == "\u5317\u4eac")
            {
                foundBeijing = true;
                assert(v.value_SZ == "China");
            }
        }
        assert(foundCologne);
        assert(foundMinsk);
        assert(foundBeijing);

        Key stateKey = unittestKey.createKey("StateCollection");
        stateKey.setValue("Germany", ["D\u00fcsseldorf", "K\u00f6ln", "Hamburg"]);
        Value v = stateKey.getValue("Germany");
        string[] actual = v.value_MULTI_SZ;
        assert(actual.length == 3);
        assert(actual[0] == "D\u00fcsseldorf");
        assert(actual[1] == "K\u00f6ln");
        assert(actual[2] == "Hamburg");

        Key numberKey = unittestKey.createKey("Number");
        numberKey.setValue("One", 1);
        Value one = numberKey.getValue("One");
        assert(one.value_SZ == "1");
        assert(one.value_DWORD == 1);

        unittestKey.deleteKey(numberKey.name);
        unittestKey.deleteKey(stateKey.name);
        unittestKey.deleteKey(cityKey.name);
        HKCU.deleteKey(unittestKeyName);
    }
}
