////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Copyright (c) 2019 kodachi79
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
module msver;

import std.algorithm;
import std.range;

enum VersionPart
{
    Major,
    Minor,
    Build,
    Revision,
    Count
}

struct MsVer
{
    private uint[4] ids = [0, 0, 0, 0];
    private bool isValid = false;

    this(string ver)
    {
        import std.array : array;
        import std.conv : to;
        import std.regex : matchAll, regex;

        isValid = false;
        if (ver.empty)
            return;

        auto re = regex(`^(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:\.(\d+))?$`);
        auto m = ver.matchAll(re);
        if (m.empty)
            return;

        foreach (i, ref id; ids)
        {
            if (!m.captures[i + 1].empty)
                id = m.captures[i + 1].to!uint;
        }

        isValid = true;
    }

    string toString() const
    {
        import std.string : format;

        return isValid ? "%(%s.%)".format(ids) : "<invalid_version>";
    }

    @property bool valid() const
    {
        return isValid;
    }

    uint part(VersionPart p) const
    {
        return ids[p];
    }

    int opCmp(ref const MsVer rhs) const
    in
    {
        assert(this.isValid);
        assert(rhs.isValid);
    }
    body
    {
        foreach (i; 0 .. ids.length)
        {
            if (ids[i] != rhs.ids[i])
                return ids[i] < rhs.ids[i] ? -1 : 1;
        }
        return 0;
    }

    int opCmp(in MsVer rhs) const
    {
        return this.opCmp(rhs);
    }

    ulong toHash() const nothrow @trusted
    in
    {
        assert(this.isValid);
    }
    do
    {
        import std.digest.murmurhash : MurmurHash3;

        auto mh = new MurmurHash3!(32);
        foreach (i; 0 .. ids.length)
            mh.putElement(ids[i]);
        mh.finish();

        return mh.get();
    }

    bool opEquals(ref const MsVer rhs) const
    {
        return this.opCmp(rhs) == 0;
    }

    bool opEquals(in MsVer rhs) const
    {
        return this.opEquals(rhs);
    }

    VersionPart differAt(ref const MsVer rhs) const
    {
        foreach (i; VersionPart.Major .. VersionPart.Revision)
        {
            if (ids[i] != rhs.ids[i])
                return i;
        }
        return VersionPart.Count;
    }

    VersionPart differAt(in MsVer rhs) const
    {
        return this.differAt(rhs);
    }
}

unittest
{
    assert(!MsVer("blah").valid);
    assert(MsVer("1.0.0").valid);

    assert(MsVer("1.0.1").differAt(MsVer("1.0.0")) == 2);
    
    assert(MsVer("1.0.0.1") == MsVer("1.0.0.1"));
    assert(MsVer("1.0.0.1") < MsVer("1.0.0.2"));
    assert(MsVer("1.0.2.12") > MsVer("1.0.1.24"));

    assert(MsVer("1.0.0.12").toString() == "1.0.0.12");
}