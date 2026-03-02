Name:		golang
Version:	v1.21
Release:	1%{?dist}
Summary:	Go install from source
Group:		Fake
License:	BSD
BuildRoot:	%(mktemp -ud %{_tmppath}/%{name}-%{version}-%{release}-XXXXXX)
Provides:	golang
BuildArch:	noarch
%description
%{summary}
%prep
%setup -c -T
%build
%install
%files
%defattr(-,root,root,-)
%changelog
* Thu Sep 2028 Hongkai Liu <hongkailiu@users.noreply.github.com> 0.0-1
- Initial change
EOF
