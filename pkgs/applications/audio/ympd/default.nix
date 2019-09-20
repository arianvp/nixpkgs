{ stdenv, fetchFromGitHub, cmake, pkgconfig, mpd_clientlib, openssl }:

stdenv.mkDerivation rec {
  pname = "ympd";
  version = "1.4.0-rc1";

  src = fetchFromGitHub {
    owner = "mayflower";
    repo = "maympd";
    rev = "25e428289a31433482b1e7cafbf572496943d193";
    sha256 = "0sg8r4fpb4gja8adz6043h1qsl7z626llzqysr87q8rrl9ij1j8g";
  };

  nativeBuildInputs = [ cmake pkgconfig ];
  buildInputs = [ mpd_clientlib openssl ];

  meta = {
    homepage = https://www.ympd.org;
    description = "Standalone MPD Web GUI written in C, utilizing Websockets and Bootstrap/JS";
    maintainers = [ stdenv.lib.maintainers.siddharthist ];
    platforms = stdenv.lib.platforms.unix;
    license = stdenv.lib.licenses.gpl2;
  };
}
